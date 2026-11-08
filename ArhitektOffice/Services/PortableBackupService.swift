import CryptoKit
import Foundation
import SwiftData

/// Native document package: data.json plus original recordings and their journals.
/// Credentials and cloud settings live outside the database and are never exported.
@MainActor
enum PortableBackupService {
    static let maximumAudioBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private nonisolated static var manager: FileManager { FileManager.default }

    enum PackageError: LocalizedError {
        case invalid(String), missing(String), conflict(String), tooLarge, recordingActive, processingActive
        var errorDescription: String? {
            switch self {
            case .invalid(let detail): "Paket sigurnosne kopije nije valjan: \(detail)"
            case .missing(let path): "Nedostaje audio datoteka: \(path). Izvorni podaci nisu promijenjeni."
            case .conflict(let path): "Na uređaju već postoji drukčija datoteka \(path). Uvoz je zaustavljen bez prepisivanja zvuka."
            case .tooLarge: "Paket prelazi ograničenje od 2 GB. Izvezite JSON i zasebno sačuvajte velike snimke."
            case .recordingActive: "Prije sigurnosne kopije završite aktivno ili pauzirano snimanje."
            case .processingActive: "Prije sigurnosne kopije pričekajte završetak ili pauzirajte lokalnu AI obradu."
            }
        }
    }

    /// URL-backed wrappers defer loading CAF data until the document writer needs
    /// it; preparation never builds one giant Data containing the entire package.
    static func export(context: ModelContext, recordingStore: RecordingFileStore = .shared) throws -> FileWrapper {
        try ensureIdle()
        guard !context.hasChanges else { throw BackupError.unsavedChanges }
        let data = try BackupService.export(context: context)
        let container = try validatedContainer(data)
        let recordings = try container.mainContext.fetch(FetchDescriptor<RecordingSession>())
        let files = try audioFiles(recordings: recordings, root: recordingStore.rootDirectory, store: recordingStore)
        var audioChildren: [String: FileWrapper] = [:]
        for recording in recordings {
            let prefix = recording.id.uuidString + "/"
            let selected = files.filter { $0.relativePath.hasPrefix(prefix) }
            guard !selected.isEmpty else { continue }
            var recordingChildren: [String: FileWrapper] = [:]
            var chunks: [String: FileWrapper] = [:]
            for file in selected {
                let local = String(file.relativePath.dropFirst(prefix.count))
                let wrapper = try FileWrapper(url: file.url, options: [])
                wrapper.preferredFilename = file.url.lastPathComponent
                if local.hasPrefix("chunks/") { chunks[file.url.lastPathComponent] = wrapper }
                else { recordingChildren[local] = wrapper }
            }
            if !chunks.isEmpty { recordingChildren["chunks"] = FileWrapper(directoryWithFileWrappers: chunks) }
            audioChildren[recording.id.uuidString] = FileWrapper(directoryWithFileWrappers: recordingChildren)
        }
        return FileWrapper(directoryWithFileWrappers: [
            "data.json": FileWrapper(regularFileWithContents: data),
            "audio": FileWrapper(directoryWithFileWrappers: audioChildren)
        ])
    }

    /// Validates everything before staging, refuses byte-different existing files,
    /// installs only missing files, then performs one atomic metadata import/save.
    /// A process termination between filesystem installation and DB commit may
    /// leave unreferenced audio. Retrying adopts matching files without data loss.
    static func importPackage(at packageURL: URL, into context: ModelContext,
                              recordingStore: RecordingFileStore = .shared) async throws -> ImportResult {
        try ensureIdle()
        guard !context.hasChanges else { throw BackupError.unsavedChanges }
        try inspect(packageURL, directory: true)
        let children = try names(in: packageURL)
        guard children.isSubset(of: ["data.json", "audio"]), children.contains("data.json") else {
            throw PackageError.invalid("očekuje se data.json i mapa audio")
        }
        let jsonURL = packageURL.appendingPathComponent("data.json")
        let size = try inspect(jsonURL, directory: false)
        guard size <= Int64(BackupService.maximumBytes) else { throw BackupError.tooLarge }
        let data = try Data(contentsOf: jsonURL)
        // Real import into a throwaway store exercises schema, enum, provenance and
        // relationship validation before touching the user's recording directory.
        let validation = try validatedContainer(data)
        let recordings = try validation.mainContext.fetch(FetchDescriptor<RecordingSession>())
        let audioRoot = packageURL.appendingPathComponent("audio", isDirectory: true)
        let hasAudio = children.contains("audio")
        if hasAudio { try inspect(audioRoot, directory: true) }
        let incoming = try audioFiles(recordings: recordings, root: audioRoot, store: recordingStore)
        if hasAudio {
            let expectedIDs = Set(recordings.map { $0.id.uuidString })
            guard try names(in: audioRoot).isSubset(of: expectedIDs) else {
                throw PackageError.invalid("audio mapa sadrži nepoznatu snimku")
            }
        }
        let rootDirectory = recordingStore.rootDirectory
        let worker = Task.detached(priority: .userInitiated) {
            try installAudio(incoming, rootDirectory: rootDirectory)
        }
        let receipt = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        do {
            try Task.checkCancellation()
            try ensureIdle()
            return try BackupService.importData(data, into: context)
        } catch {
            await Task.detached { rollback(receipt) }.value
            throw error
        }
    }

    private struct InstallReceipt: Sendable {
        var installed: [URL]
        var createdDirectories: [URL]
    }

    private nonisolated static func installAudio(_ incoming: [AudioFile], rootDirectory: URL) throws -> InstallReceipt {
        let recordingStore = RecordingFileStore(rootDirectory: rootDirectory)
        // Hash and copy on a background worker. Metadata was validated earlier;
        // no context or managed model crosses this isolation boundary.
        var missing: [(AudioFile, URL)] = []
        for file in incoming {
            try Task.checkCancellation()
            let destination = try safeDestination(file.relativePath, store: recordingStore)
            if manager.fileExists(atPath: destination.path) {
                try inspect(destination, directory: false)
                guard try digest(file.url) == digest(destination) else { throw PackageError.conflict(file.relativePath) }
            } else { missing.append((file, destination)) }
        }
        try recordingStore.createProtectedDirectory(recordingStore.rootDirectory)
        let staging = recordingStore.rootDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try recordingStore.createProtectedDirectory(staging)
        defer { try? manager.removeItem(at: staging) }
        var receipt = InstallReceipt(installed: [], createdDirectories: [])
        do {
            for (file, _) in missing {
                try Task.checkCancellation()
                let staged = staging.appendingPathComponent(file.relativePath)
                try recordingStore.createProtectedDirectory(staged.deletingLastPathComponent())
                try manager.copyItem(at: file.url, to: staged)
                guard try digest(staged) == digest(file.url) else {
                    throw PackageError.invalid("datoteka se promijenila tijekom kopiranja")
                }
            }
            for (file, destination) in missing {
                try Task.checkCancellation()
                _ = try safeDestination(file.relativePath, store: recordingStore)
                try createDirectories(to: destination.deletingLastPathComponent(), root: recordingStore.rootDirectory,
                                      store: recordingStore, created: &receipt.createdDirectories)
                try manager.moveItem(at: staging.appendingPathComponent(file.relativePath), to: destination)
                receipt.installed.append(destination)
                try recordingStore.protect(file.relativePath)
            }
            return receipt
        } catch {
            rollback(receipt)
            throw error
        }
    }

    private nonisolated static func rollback(_ receipt: InstallReceipt) {
        for url in receipt.installed.reversed() { try? manager.removeItem(at: url) }
        for url in receipt.createdDirectories.reversed() {
            if (try? manager.contentsOfDirectory(atPath: url.path).isEmpty) == true { try? manager.removeItem(at: url) }
        }
    }

    private struct AudioFile: Sendable {
        var relativePath: String
        var url: URL
    }

    private static func audioFiles(recordings: [RecordingSession], root: URL,
                                   store: RecordingFileStore) throws -> [AudioFile] {
        guard manager.fileExists(atPath: root.path) else {
            if let recording = recordings.first(where: { $0.masterRelativePath != nil }) {
                throw PackageError.missing(store.masterPath(for: recording.id))
            }
            return []
        }
        try inspect(root, directory: true)
        var result: [AudioFile] = []
        var total: Int64 = 0
        for recording in recordings {
            let id = recording.id
            let canonicalMaster = store.masterPath(for: id)
            let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            guard manager.fileExists(atPath: directory.path) else {
                if recording.masterRelativePath != nil { throw PackageError.missing(canonicalMaster) }
                continue
            }
            try inspect(directory, directory: true)
            let directoryNames = try names(in: directory)
            let checkpointNames = Set(directoryNames.filter(isCheckpointFilename))
            let audioNames: Set<String> = ["master.caf", "recovery.json", "chunks"]
            let allowed = recording.masterRelativePath == nil ? checkpointNames : audioNames.union(checkpointNames)
            guard directoryNames.isSubset(of: allowed) else {
                throw PackageError.invalid("nepoznata datoteka u snimci")
            }
            var required = Set<String>()
            for name in checkpointNames {
                let url = directory.appendingPathComponent(name)
                guard try inspect(url, directory: false) <= Int64(BackupService.maximumBytes) else {
                    throw PackageError.invalid("prevelik lokalni dnevnik transkripcije")
                }
                // Even a corrupt partial journal can contain valuable text. Keep
                // these bounded files opaque, including after explicit audio
                // deletion. The checkpoint store validates ID/window/source/model
                // before any journal can be resumed; package import trusts none.
                required.insert("\(id.uuidString)/\(name)")
            }
            if recording.masterRelativePath != nil {
                guard recording.masterRelativePath == canonicalMaster else { throw PackageError.invalid("nesigurna putanja izvorne snimke") }
                let recoveryURL = directory.appendingPathComponent("recovery.json")
                guard manager.fileExists(atPath: recoveryURL.path) else { throw PackageError.missing("\(id.uuidString)/recovery.json") }
                guard try inspect(recoveryURL, directory: false) <= 2 * 1_024 * 1_024 else {
                    throw PackageError.invalid("prevelik dnevnik oporavka")
                }
                let journalStore = RecordingFileStore(rootDirectory: root)
                let manifest = try journalStore.readManifest(id: id)
                let expectedPaths = Set(recording.segments.filter { $0.stateRaw != "audioDeleted" }.map(\.relativePath))
                for segment in recording.segments {
                    let legacyPath = store.segmentPath(for: id, index: segment.index)
                    let localWindow = segment.stateRaw.hasPrefix("local:") && segment.relativePath == canonicalMaster
                    let deletedWindow = segment.stateRaw == "audioDeleted" && segment.relativePath == canonicalMaster
                    guard segment.index >= 0, segment.index < 1_000_000,
                          localWindow || deletedWindow || segment.relativePath == legacyPath else {
                        throw PackageError.invalid("nesigurna putanja dijela snimke")
                    }
                }
                // Local PCM windows share one physical master. Legacy cloud AAC
                // pieces and their recovery journal remain backward compatible.
                required.formUnion(expectedPaths)
                required.formUnion(manifest.segments.map(\.relativePath))
                required.insert(canonicalMaster)
                required.insert("\(id.uuidString)/recovery.json")
                let chunksDirectory = directory.appendingPathComponent("chunks", isDirectory: true)
                if manager.fileExists(atPath: chunksDirectory.path) {
                    try inspect(chunksDirectory, directory: true)
                    for name in try names(in: chunksDirectory) {
                        guard name.range(of: #"^[0-9]{6}\.m4a$"#, options: .regularExpression) != nil else {
                            throw PackageError.invalid("nepoznat dio snimke")
                        }
                        required.insert("\(id.uuidString)/chunks/\(name)")
                    }
                }
            }
            for relativePath in required.sorted() {
                let url = root.appendingPathComponent(relativePath)
                guard manager.fileExists(atPath: url.path) else { throw PackageError.missing(relativePath) }
                let size = try inspect(url, directory: false)
                guard size >= 0, size <= maximumAudioBytes, total <= maximumAudioBytes - size else { throw PackageError.tooLarge }
                total += size
                result.append(AudioFile(relativePath: relativePath, url: url))
            }
        }
        return result
    }

    private static func isCheckpointFilename(_ name: String) -> Bool {
        if name == "local-transcription-v1.json" { return true }
        let prefix = "local-transcription-history-"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return false }
        let token = String(name.dropFirst(prefix.count).dropLast(5))
        return UUID(uuidString: token)?.uuidString == token
    }

    private static func validatedContainer(_ data: Data) throws -> ModelContainer {
        let schema = Schema([Project.self, ProjectTask.self, ProjectIssue.self, ProjectNote.self,
                             PhaseChange.self, RecordingSession.self, AudioSegment.self,
                             TranscriptVersion.self, MemoryEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.autosaveEnabled = false
        _ = try BackupService.importData(data, into: container.mainContext)
        return container
    }

    @discardableResult
    private nonisolated static func inspect(_ url: URL, directory: Bool) throws -> Int64 {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let kind = attributes[.type] as? FileAttributeType
        guard kind == (directory ? .typeDirectory : .typeRegular) else {
            throw PackageError.invalid("simbolička poveznica ili neočekivana vrsta datoteke")
        }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private nonisolated static func names(in directory: URL) throws -> Set<String> {
        Set(try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map(\.lastPathComponent))
    }

    private nonisolated static func safeDestination(_ path: String, store: RecordingFileStore) throws -> URL {
        let destination = try store.url(for: path)
        let lexical = store.rootDirectory.standardizedFileURL.appendingPathComponent(path)
        var candidate = lexical
        let root = store.rootDirectory.standardizedFileURL
        while candidate.path.hasPrefix(root.path + "/") || candidate == root {
            do {
                let attributes = try manager.attributesOfItem(atPath: candidate.path)
                guard (attributes[.type] as? FileAttributeType) != .typeSymbolicLink else {
                    throw PackageError.invalid("poveznica u odredištu snimke")
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // A not-yet-created component is expected. attributesOfItem also
                // detects dangling symlinks, unlike fileExists(atPath:).
            }
            if candidate == root { break }
            candidate.deleteLastPathComponent()
        }
        return destination
    }

    private nonisolated static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize()
    }

    private nonisolated static func createDirectories(to directory: URL, root: URL, store: RecordingFileStore,
                                          created: inout [URL]) throws {
        guard directory.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        if manager.fileExists(atPath: directory.path) { try inspect(directory, directory: true); return }
        try createDirectories(to: directory.deletingLastPathComponent(), root: root, store: store, created: &created)
        try store.createProtectedDirectory(directory)
        created.append(directory)
    }

    private static func ensureIdle() throws {
        let state = LongRecordingService.shared.state
        guard state != .recording, state != .paused, state != .preparing else { throw PackageError.recordingActive }
        guard !LocalInferenceCoordinator.shared.isBusy else { throw PackageError.processingActive }
    }
}
