import AVFoundation
import Foundation

/// Files survive transcription failures and app restarts. The recovery journal is
/// created before the microphone starts; audio is never deleted implicitly.
struct RecordingFileStore {
    static let shared = RecordingFileStore()
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArhitektOffice/Recordings", isDirectory: true)
    }

    struct SegmentEntry: Codable, Equatable {
        var index: Int
        var relativePath: String
        var duration: Double
    }

    struct Manifest: Codable, Equatable {
        var version = 1
        var id: UUID
        var projectID: UUID?
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var masterRelativePath: String
        var duration: Double
        var state: String
        var segments: [SegmentEntry] = []
    }

    struct RecoveryScan {
        var manifests: [Manifest]
        var warnings: [String]
    }

    func masterPath(for id: UUID) -> String { "\(id.uuidString)/master.caf" }
    func segmentPath(for id: UUID, index: Int) -> String {
        "\(id.uuidString)/chunks/\(String(format: "%06d", index)).m4a"
    }

    /// Reject path traversal and symlinks that escape the protected recording root.
    func url(for relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StoreError.invalidPath
        }
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let result = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard result.path.hasPrefix(root.path + "/") else { throw StoreError.invalidPath }
        return result
    }

    func createManifest(id: UUID, title: String, projectID: UUID?, createdAt: Date = Date()) throws -> Manifest {
        let manifest = Manifest(id: id, projectID: projectID, title: title,
                                createdAt: createdAt, updatedAt: createdAt,
                                masterRelativePath: masterPath(for: id), duration: 0, state: "preparing")
        let destination = try manifestURL(for: id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StoreError.alreadyExists }
        try write(manifest)
        return manifest
    }

    func write(_ manifest: Manifest) throws {
        try validate(manifest)
        let destination = try manifestURL(for: manifest.id)
        try createProtectedDirectory(destination.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func readManifest(id: UUID) throws -> Manifest {
        let data = try Data(contentsOf: manifestURL(for: id))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.id == id else { throw StoreError.invalidManifest }
        try validate(manifest)
        return manifest
    }

    func scanRecoveryManifests() throws -> RecoveryScan {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return RecoveryScan(manifests: [], warnings: [])
        }
        let urls = try FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        var result = RecoveryScan(manifests: [], warnings: [])
        for directory in urls {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let journal = directory.appendingPathComponent("recovery.json")
            // Explicit audio deletion retains text checkpoints in this folder.
            // Their absence of a recovery journal is expected, not corruption.
            if !FileManager.default.fileExists(atPath: journal.path),
               !FileManager.default.fileExists(atPath: directory.appendingPathComponent("master.caf").path),
               !FileManager.default.fileExists(atPath: directory.appendingPathComponent("master.m4a").path) { continue }
            do { result.manifests.append(try readManifest(id: id)) }
            catch {
                result.warnings.append("Dnevnik snimke \(id.uuidString) nije čitljiv. Audio datoteke nisu izbrisane.")
            }
        }
        result.manifests.sort { $0.createdAt < $1.createdAt }
        return result
    }

    func createProtectedDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    func protect(_ relativePath: String) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url(for: relativePath).path)
    }

    /// Used only after an explicit user request. Delete only app-owned audio;
    /// text checkpoints (even unreadable diagnostic history) and unknown files stay.
    func deleteAudio(id: UUID) throws {
        let manager = FileManager.default
        let lexicalDirectory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard manager.fileExists(atPath: lexicalDirectory.path) else { return }
        guard try lexicalDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw StoreError.invalidPath
        }
        let directory = try url(for: id.uuidString)
        var removals: [URL] = []
        for name in ["master.caf", "master.m4a", "recovery.json"] {
            let candidate = directory.appendingPathComponent(name)
            if manager.fileExists(atPath: candidate.path),
               try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { removals.append(candidate) }
        }
        for candidate in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = candidate.deletingPathExtension().lastPathComponent
            if candidate.pathExtension == "m4a", name.hasPrefix("export-"),
               UUID(uuidString: String(name.dropFirst(7))) != nil,
               try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { removals.append(candidate) }
        }
        let chunks = directory.appendingPathComponent("chunks", isDirectory: true)
        let chunksExist = manager.fileExists(atPath: chunks.path)
        var chunksValues: URLResourceValues?
        if chunksExist { chunksValues = try chunks.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) }
        if chunksValues?.isSymbolicLink == true { throw StoreError.invalidPath }
        let hasChunksDirectory = chunksValues?.isDirectory == true
        if hasChunksDirectory {
            for candidate in try manager.contentsOfDirectory(at: chunks, includingPropertiesForKeys: [.isDirectoryKey]) {
                let name = candidate.deletingPathExtension().lastPathComponent
                let canonicalChunk = name.count == 6 && name.allSatisfy { $0.isASCII && $0.isNumber }
                let exportTemporary = name.hasPrefix("export-") && UUID(uuidString: String(name.dropFirst(7))) != nil
                if candidate.pathExtension == "m4a", canonicalChunk || exportTemporary,
                   try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { removals.append(candidate) }
            }
        }
        // Known files are removed lexically, so a symlink is unlinked rather than
        // following it to another recording. Unknown content is never traversed.
        for candidate in removals { try manager.removeItem(at: candidate) }
        if hasChunksDirectory, try manager.contentsOfDirectory(atPath: chunks.path).isEmpty {
            try manager.removeItem(at: chunks)
        }
        if try manager.contentsOfDirectory(atPath: directory.path).isEmpty { try manager.removeItem(at: directory) }
    }

    /// Optional local AAC export for compatibility and user backups. Whisper reads
    /// bounded PCM windows directly from the retained master instead.
    /// Export complete, ordered pieces from a continuous master. The master is
    /// retained. An interrupted export can be retried without affecting it.
    func exportSegments(id: UUID, masterRelativePath: String, maximumDuration: Double = 60) async throws -> [SegmentEntry] {
        guard maximumDuration > 0, maximumDuration <= 60 else { throw StoreError.invalidDuration }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: try url(for: masterRelativePath))
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw StoreError.unreadableAudio }
        let count = Int(ceil(duration / maximumDuration))
        var entries: [SegmentEntry] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let offset = Double(index) * maximumDuration
            let length = min(maximumDuration, duration - offset)
            let relativePath = segmentPath(for: id, index: index)
            let destination = try url(for: relativePath)
            try createProtectedDirectory(destination.deletingLastPathComponent())
            // Export to a unique temporary filename, then atomically replace the
            // destination. A failed re-export leaves any old valid chunk intact.
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent("export-\(UUID().uuidString).m4a")
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw StoreError.unreadableAudio
            }
            exporter.outputURL = temporary
            exporter.outputFileType = .m4a
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                                           duration: CMTime(seconds: length, preferredTimescale: 600))
            do {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        exporter.exportAsynchronously { continuation.resume() }
                    }
                } onCancel: {
                    exporter.cancelExport()
                }
                try Task.checkCancellation()
                guard exporter.status == .completed else {
                    if let error = exporter.error { throw error }
                    throw StoreError.exportFailed
                }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                entries.append(SegmentEntry(index: index, relativePath: relativePath, duration: length))
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
        return entries
    }

    private func manifestURL(for id: UUID) throws -> URL { try url(for: "\(id.uuidString)/recovery.json") }

    private func validate(_ manifest: Manifest) throws {
        guard manifest.version == 1, manifest.duration.isFinite, manifest.duration >= 0,
              manifest.masterRelativePath == masterPath(for: manifest.id),
              Set(manifest.segments.map(\.index)).count == manifest.segments.count else {
            throw StoreError.invalidManifest
        }
        _ = try url(for: manifest.masterRelativePath)
        for segment in manifest.segments {
            guard segment.index >= 0, segment.duration.isFinite, segment.duration > 0,
                  segment.relativePath == segmentPath(for: manifest.id, index: segment.index) else {
                throw StoreError.invalidManifest
            }
            _ = try url(for: segment.relativePath)
        }
    }

    enum StoreError: LocalizedError {
        case invalidPath, alreadyExists, invalidManifest, invalidDuration, unreadableAudio, exportFailed
        var errorDescription: String? {
            switch self {
            case .invalidPath: "Putanja audio datoteke nije valjana."
            case .alreadyExists: "Snimka s ovim identifikatorom već postoji."
            case .invalidManifest: "Dnevnik oporavka snimke nije valjan."
            case .invalidDuration: "Trajanje dijelova snimke nije valjano."
            case .unreadableAudio: "Snimku nije moguće pročitati. Izvorna datoteka ostaje sačuvana."
            case .exportFailed: "Priprema dijelova snimke nije uspjela. Izvorna datoteka ostaje sačuvana."
            }
        }
    }
}
