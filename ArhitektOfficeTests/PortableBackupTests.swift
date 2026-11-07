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
