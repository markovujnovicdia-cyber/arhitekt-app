import Foundation
import SwiftData
import XCTest
@testable import ArhitektOffice

@MainActor
final class PortableBackupTests: XCTestCase {
    private var schema: Schema {
        Schema([Project.self, ProjectTask.self, ProjectIssue.self, ProjectNote.self, PhaseChange.self,
                RecordingSession.self, AudioSegment.self, TranscriptVersion.self, MemoryEntry.self])
    }

    private func container() throws -> ModelContainer {
        let result = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        result.mainContext.autosaveEnabled = false
        return result
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Fixture {
        let container: ModelContainer
        let store: RecordingFileStore
        let recordingID: UUID
        let transcriptID: UUID
        let packageURL: URL
    }

    private func fixture() throws -> Fixture {
        let directory = try temporaryDirectory()
        let store = RecordingFileStore(rootDirectory: directory.appendingPathComponent("source"))
        let source = try container()
        let project = Project(name: "Kuća Cerje")
        source.mainContext.insert(project)
        let session = RecordingSession(title: "Razgovor s investitorom", project: project)
        session.masterRelativePath = store.masterPath(for: session.id)
        session.duration = 75
        source.mainContext.insert(session)
        let segment = AudioSegment(index: 0, relativePath: store.segmentPath(for: session.id, index: 0), duration: 60, session: session)
        source.mainContext.insert(segment)
        let transcript = TranscriptVersion(text: "Investitor je potvrdio glavni ulaz.", recording: session)
        source.mainContext.insert(transcript)
        var manifest = try store.createManifest(id: session.id, title: session.title, projectID: project.id)
        manifest.duration = 75
        manifest.state = "stopped"
        manifest.segments = [.init(index: 0, relativePath: segment.relativePath, duration: 60)]
        try store.write(manifest)
        // File integrity tests use deterministic bytes; actual CAF decoding belongs
        // to the recording/device tests, not portable package validation.
        try Data("CAFF source audio bytes".utf8).write(to: store.url(for: session.masterRelativePath!))
        let chunkURL = try store.url(for: segment.relativePath)
        try store.createProtectedDirectory(chunkURL.deletingLastPathComponent())
        try Data("AAC segment bytes".utf8).write(to: chunkURL)
        try source.mainContext.save()
        let package = try PortableBackupService.export(context: source.mainContext, recordingStore: store)
        let packageURL = directory.appendingPathComponent("test.officebackup", isDirectory: true)
        try package.write(to: packageURL, options: .atomic, originalContentsURL: nil)
        return Fixture(container: source, store: store, recordingID: session.id, transcriptID: transcript.id, packageURL: packageURL)
    }

    private func localFixture() throws -> Fixture {
        let value = try fixture()
        let context = value.container.mainContext
        let recording = try XCTUnwrap(context.fetch(FetchDescriptor<RecordingSession>()).first)
        for segment in recording.segments { context.delete(segment) }
        try context.save()
        let chunks = try value.store.url(for: "\(recording.id.uuidString)/chunks")
        try FileManager.default.removeItem(at: chunks)
        var manifest = try value.store.readManifest(id: recording.id)
        manifest.segments = []
        try value.store.write(manifest)
        let fingerprint = String(repeating: "a", count: 64)
        var windows: [LocalTranscriptionCheckpoint.Result] = []
        for index in 0..<3 {
            let start = Int64(index * 400_000)
            let window = LocalAudioReader.Window(index: index, sourceStartFrame: max(0, start - 16_000),
                ownedStartFrame: start, endFrame: start + 400_000, sourceSampleRate: 16_000)
            windows.append(.init(window: window, text: "Lokalni dio \(index + 1).", completed: true))
            let segment = AudioSegment(index: index, relativePath: value.store.masterPath(for: recording.id),
                                       duration: window.ownedDuration, session: recording)
            segment.transcriptText = "Lokalni dio \(index + 1)."
            segment.stateRaw = "local:\(fingerprint):completed"
            context.insert(segment)
        }
        let masterURL = try value.store.url(for: value.store.masterPath(for: recording.id))
        let size = try masterURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let source = LocalAudioReader.SourceFingerprint(frameCount: 1_200_000, sampleRate: 16_000,
                                                        byteCount: Int64(size), modifiedAt: Date())
        let checkpoint = LocalTranscriptionCheckpoint(recordingID: recording.id, modelFingerprint: fingerprint,
                                                      source: source, windows: windows)
        let checkpoints = LocalTranscriptionCheckpointStore(files: value.store)
        try checkpoints.save(checkpoint)
        try checkpoints.archiveExisting(recordingID: recording.id)
        // Real failures may archive unreadable partial journals. Preserve those
        // text bytes too, even though they must never be trusted for resumption.
        let history = try value.store.url(for: "\(recording.id.uuidString)/local-transcription-history-\(UUID().uuidString).json")
        try Data("damaged journal with partial text".utf8).write(to: history)
        try context.save()
        try FileManager.default.removeItem(at: value.packageURL)
        let package = try PortableBackupService.export(context: context, recordingStore: value.store)
        try package.write(to: value.packageURL, options: .atomic, originalContentsURL: nil)
        return value
    }

    func testLocalPCMWindowsShareSingleMasterAndPreserveCheckpointHistoryRoundTrip() async throws {
        let source = try localFixture()
        let metadata = try BackupService.export(context: source.container.mainContext)
        XCTAssertEqual(try BackupService.audioRelativePaths(in: metadata), [source.store.masterPath(for: source.recordingID)])
        let packageSession = source.packageURL.appendingPathComponent("audio/\(source.recordingID.uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageSession.appendingPathComponent("chunks").path))
        let target = try container()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("local"))
        _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
        _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<RecordingSession>()).first)
        XCTAssertEqual(restored.segments.count, 3)
        XCTAssertTrue(restored.segments.allSatisfy { $0.relativePath == destination.masterPath(for: source.recordingID) })
        XCTAssertTrue(restored.segments.allSatisfy { $0.stateRaw.hasPrefix("local:") })
        XCTAssertEqual(restored.segments.map(\.transcriptText), ["Lokalni dio 1.", "Lokalni dio 2.", "Lokalni dio 3."])
        let names = try FileManager.default.contentsOfDirectory(atPath: packageSession.path)
        XCTAssertEqual(names.filter { $0 == "master.caf" }.count, 1)
        for name in names {
            let relative = "\(source.recordingID.uuidString)/\(name)"
            XCTAssertEqual(try Data(contentsOf: source.store.url(for: relative)), try Data(contentsOf: destination.url(for: relative)))
        }
        let checkpoint = try XCTUnwrap(LocalTranscriptionCheckpointStore(files: destination).load(recordingID: source.recordingID))
        XCTAssertEqual(checkpoint.windows.count, 3)
        XCTAssertTrue(checkpoint.windows.allSatisfy(\.completed))
    }

    func testLocalPCMMarkerCannotReferenceAnotherFileOrInvalidModelFingerprint() throws {
        let source = try localFixture()
        let data = try BackupService.export(context: source.container.mainContext)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        segments[0]["relativePath"] = "\(UUID().uuidString)/master.caf"
        json["segments"] = segments
        XCTAssertThrowsError(try BackupService.validate(data: JSONSerialization.data(withJSONObject: json)))
        segments[0]["relativePath"] = source.store.masterPath(for: source.recordingID)
        segments[0]["stateRaw"] = "local:not-a-model-sha:completed"
        json["segments"] = segments
        XCTAssertThrowsError(try BackupService.validate(data: JSONSerialization.data(withJSONObject: json)))
    }

    func testCheckpointOnlyPackageRetainsTextAfterExplicitAudioDeletion() async throws {
        let source = try localFixture()
        let recording = try XCTUnwrap(source.container.mainContext.fetch(FetchDescriptor<RecordingSession>()).first)
        let directory = try source.store.url(for: source.recordingID.uuidString)
        for name in ["master.caf", "recovery.json"] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        recording.masterRelativePath = nil
        recording.stateRaw = "audioDeleted"
        for segment in recording.segments { segment.stateRaw = "audioDeleted" }
        try source.container.mainContext.save()
        try FileManager.default.removeItem(at: source.packageURL)
        let package = try PortableBackupService.export(context: source.container.mainContext, recordingStore: source.store)
        try package.write(to: source.packageURL, options: .atomic, originalContentsURL: nil)
        let target = try container()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("checkpoint-only"))
        _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<RecordingSession>()).first)
        XCTAssertNil(restored.masterRelativePath)
        XCTAssertEqual(restored.stateRaw, "audioDeleted")
        XCTAssertEqual(restored.latestTranscript?.id, source.transcriptID)
        let checkpoint = try XCTUnwrap(LocalTranscriptionCheckpointStore(files: destination).load(recordingID: source.recordingID))
        XCTAssertEqual(checkpoint.windows.map(\.text), ["Lokalni dio 1.", "Lokalni dio 2.", "Lokalni dio 3."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try destination.url(for: destination.masterPath(for: source.recordingID)).path))
        let sourceNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let restoredDirectory = try destination.url(for: source.recordingID.uuidString)
        XCTAssertEqual(Set(sourceNames), Set(try FileManager.default.contentsOfDirectory(atPath: restoredDirectory.path)))
    }

    func testRoundTripCopiesMasterChunksJournalAndAllMetadataIdempotently() async throws {
        let source = try fixture()
        let target = try container()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("restored"))
        _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
        _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<RecordingSession>()).first)
        XCTAssertEqual(restored.id, source.recordingID)
        XCTAssertEqual(restored.latestTranscript?.id, source.transcriptID)
        XCTAssertEqual(restored.project?.name, "Kuća Cerje")
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<RecordingSession>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<AudioSegment>()), 1)
        for path in [destination.masterPath(for: source.recordingID), destination.segmentPath(for: source.recordingID, index: 0), "\(source.recordingID.uuidString)/recovery.json"] {
            XCTAssertEqual(try Data(contentsOf: source.store.url(for: path)), try Data(contentsOf: destination.url(for: path)))
        }
    }

    func testConflictingExistingAudioIsPreservedAndMetadataIsNotImported() async throws {
        let source = try fixture()
        let target = try container()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("existing"))
        let path = destination.masterPath(for: source.recordingID)
        let existing = try destination.url(for: path)
        try destination.createProtectedDirectory(existing.deletingLastPathComponent())
        let original = Data("Never overwrite my actual audio".utf8)
        try original.write(to: existing)
        do {
            _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
            XCTFail("Different audio bytes must reject the import")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try destination.url(for: "\(source.recordingID.uuidString)/recovery.json").path))
    }

    func testMalformedJSONFailsBeforeAnyAudioDirectoryIsCreated() async throws {
        let source = try fixture()
        try Data("not JSON".utf8).write(to: source.packageURL.appendingPathComponent("data.json"))
        let target = try container()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("unused"))
        do {
            _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
            XCTFail("Malformed metadata must fail")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.rootDirectory.path))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
    }

    func testSymlinkInPackageCannotReadOutsidePackage() async throws {
        let source = try fixture()
        let sourceMaster = source.packageURL.appendingPathComponent("audio/\(source.recordingID.uuidString)/master.caf")
        try FileManager.default.removeItem(at: sourceMaster)
        let external = try temporaryDirectory().appendingPathComponent("private.caf")
        try Data("External file must not be imported".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: sourceMaster, withDestinationURL: external)
        let target = try container()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("unused"))
        do {
            _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
            XCTFail("Symlink must fail validation")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.rootDirectory.path))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
    }

    func testMissingReferencedChunkRejectsIncompleteBackup() async throws {
        let source = try fixture()
        let chunk = source.packageURL.appendingPathComponent("audio/\(source.recordingID.uuidString)/chunks/000000.m4a")
        try FileManager.default.removeItem(at: chunk)
        let target = try container()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("unused"))
        do {
            _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
            XCTFail("Incomplete audio backup must fail")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.rootDirectory.path))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<RecordingSession>()), 0)
    }

    func testMetadataCollisionRollsBackNewAudioFilesWithoutChangingExistingTranscript() async throws {
        let source = try fixture()
        let target = try container()
        let existing = TranscriptVersion(text: "This existing immutable transcript differs")
        existing.id = source.transcriptID
        target.mainContext.insert(existing)
        try target.mainContext.save()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("restored"))
        do {
            _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
            XCTFail("Immutable transcript conflict must fail")
        } catch { }
        XCTAssertEqual(existing.text, "This existing immutable transcript differs")
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<RecordingSession>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try destination.url(for: destination.masterPath(for: source.recordingID)).path))
        XCTAssertFalse(target.mainContext.hasChanges)
    }

    func testSymlinkInsideDestinationCannotRedirectNewAudio() async throws {
        let source = try fixture()
        let target = try container()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("restored"))
        try destination.createProtectedDirectory(destination.rootDirectory)
        let outside = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(at: destination.rootDirectory.appendingPathComponent(source.recordingID.uuidString), withDestinationURL: outside)
        do {
            _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
            XCTFail("Symlink destination must fail")
        } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
    }
    func testDanglingDestinationSymlinkCannotRedirectAudioInsideStorageRoot() async throws {
        let source = try fixture()
        let target = try container()
        let destination = RecordingFileStore(rootDirectory: try temporaryDirectory().appendingPathComponent("restored"))
        try destination.createProtectedDirectory(destination.rootDirectory)
        let unexpected = destination.rootDirectory.appendingPathComponent("unexpected", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: destination.rootDirectory.appendingPathComponent(source.recordingID.uuidString), withDestinationURL: unexpected)
        do {
            _ = try await PortableBackupService.importPackage(at: source.packageURL, into: target.mainContext, recordingStore: destination)
            XCTFail("Dangling symlink must fail")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unexpected.path))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Project>()), 0)
    }

}
