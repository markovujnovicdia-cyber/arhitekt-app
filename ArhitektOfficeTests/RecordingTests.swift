import AVFoundation
import SwiftData
import XCTest
@testable import ArhitektOffice

@MainActor
final class RecordingTests: XCTestCase {
    private func store() -> RecordingFileStore {
        RecordingFileStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTests-\(UUID().uuidString)", isDirectory: true))
    }

    private func container() throws -> ModelContainer {
        let schema = Schema([Project.self, ProjectTask.self, ProjectIssue.self, ProjectNote.self, PhaseChange.self,
                             RecordingSession.self, AudioSegment.self, TranscriptVersion.self, MemoryEntry.self])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    func testRecoveryJournalExistsBeforeAnyAudioIsCreated() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let id = UUID()
        let manifest = try store.createManifest(id: id, title: "Dugi sastanak", projectID: nil)
        XCTAssertEqual(try store.readManifest(id: id), manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: manifest.masterRelativePath).path))
        XCTAssertEqual(manifest.state, "preparing")
        XCTAssertThrowsError(try store.createManifest(id: id, title: "Ne smije prepisati", projectID: nil))
        XCTAssertEqual(try store.readManifest(id: id).title, "Dugi sastanak")
    }

    func testInvalidAndEscapingPathsAreRejected() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        for path in ["", "/tmp/audio.caf", "../audio.caf", "session/../audio.caf", "session//audio.caf", "https://example.com/audio"] {
            XCTAssertThrowsError(try store.url(for: path), path)
        }
        try store.createProtectedDirectory(store.rootDirectory)
        let link = store.rootDirectory.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.rootDirectory.deletingLastPathComponent())
        XCTAssertThrowsError(try store.url(for: "outside/secret.caf"))
    }

    func testCorruptJournalNeverDeletesPartialAudio() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let id = UUID()
        let manifest = try store.createManifest(id: id, title: "Prekid", projectID: nil)
        let audio = try store.url(for: manifest.masterRelativePath)
        try Data([1, 2, 3, 4]).write(to: audio)
        try Data("nevaljani JSON".utf8).write(to: store.url(for: "\(id.uuidString)/recovery.json"))
        let scan = try store.scanRecoveryManifests()
        XCTAssertTrue(scan.manifests.isEmpty)
        XCTAssertEqual(scan.warnings.count, 1)
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3, 4]))
    }

    func testInterruptedJournalRestoresSessionAndDoesNotDuplicateItOnRetry() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let container = try container()
        let context = container.mainContext
        let project = Project(name: "Kuća Cerje")
        context.insert(project)
        try context.save()
        let id = UUID()
        var journal = try store.createManifest(id: id, title: "Sastanak investitora", projectID: project.id)
        journal.state = "interrupted"
        journal.duration = 1_200
        journal.segments = [.init(index: 0, relativePath: store.segmentPath(for: id, index: 0), duration: 60)]
        try store.write(journal)
        let service = LongRecordingService(store: store)
        let first = try service.recoverSessions(context: context)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].id, id)
        XCTAssertEqual(first[0].duration, 1_200)
        XCTAssertEqual(first[0].stateRaw, "recovered")
        XCTAssertEqual(first[0].project?.id, project.id)
        let transcript = TranscriptVersion(text: "Izvorni transkript ostaje nepromijenjen.", recording: first[0])
        context.insert(transcript)
        try context.save()
        _ = try service.recoverSessions(context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordingSession>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AudioSegment>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TranscriptVersion>()), 1)
        XCTAssertEqual(first[0].transcripts.first?.text, "Izvorni transkript ostaje nepromijenjen.")
    }

    func testLongMasterExportsInOrderWithoutDeletingOrChangingSource() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let id = UUID()
        let journal = try store.createManifest(id: id, title: "121 sekunda", projectID: nil)
        let masterURL = try store.url(for: journal.masterRelativePath)
        try writeSilentCAF(to: masterURL, seconds: 121)
        let before = try FileManager.default.attributesOfItem(atPath: masterURL.path)[.size] as? NSNumber
        let entries = try await store.exportSegments(id: id, masterRelativePath: journal.masterRelativePath)
        XCTAssertEqual(entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(entries.map(\.duration), [60, 60, 1])
        XCTAssertEqual(entries.reduce(0) { $0 + $1.duration }, 121, accuracy: 0.01)
        for entry in entries {
            let asset = AVURLAsset(url: try store.url(for: entry.relativePath))
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, entry.duration, accuracy: 0.15)
        }
        let after = try FileManager.default.attributesOfItem(atPath: masterURL.path)[.size] as? NSNumber
        XCTAssertEqual(before, after)
        XCTAssertTrue(FileManager.default.fileExists(atPath: masterURL.path))
        let retry = try await store.exportSegments(id: id, masterRelativePath: journal.masterRelativePath)
        XCTAssertEqual(entries, retry)
    }

    func testFailedPreparationRetainsOriginalAudioAndJournal() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let id = UUID()
        let journal = try store.createManifest(id: id, title: "Djelomična snimka", projectID: nil)
        let master = try store.url(for: journal.masterRelativePath)
        let original = Data("partial-audio-not-yet-readable".utf8)
        try original.write(to: master)
        do {
            _ = try await store.exportSegments(id: id, masterRelativePath: journal.masterRelativePath)
            XCTFail("Oštećena snimka ne smije proizvesti lažan uspjeh.")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: master), original)
        XCTAssertEqual(try store.readManifest(id: id), journal)
    }

    func testCancelledExportRetainsMasterAndJournal() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let id = UUID()
        let journal = try store.createManifest(id: id, title: "Otkazivanje obrade", projectID: nil)
        let master = try store.url(for: journal.masterRelativePath)
        try writeSilentCAF(to: master, seconds: 2)
        let task = Task { try await store.exportSegments(id: id, masterRelativePath: journal.masterRelativePath) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Otkazani izvoz ne smije prijaviti uspjeh.")
        } catch is CancellationError { }
        catch { XCTFail("Očekivano otkazivanje, dobiveno: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: master.path))
        XCTAssertEqual(try store.readManifest(id: id), journal)
    }

    func testExplicitAudioDeletionPreservesTranscriptAndOtherRecordings() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let container = try container()
        let context = container.mainContext
        let first = RecordingSession(title: "Za brisanje zvuka")
        let second = RecordingSession(title: "Zadrži")
        let manifest = try store.createManifest(id: first.id, title: first.title, projectID: nil)
        let otherManifest = try store.createManifest(id: second.id, title: second.title, projectID: nil)
        first.masterRelativePath = manifest.masterRelativePath
        second.masterRelativePath = otherManifest.masterRelativePath
        try Data([1, 2, 3]).write(to: store.url(for: manifest.masterRelativePath))
        try Data([4, 5, 6]).write(to: store.url(for: otherManifest.masterRelativePath))
        context.insert(first)
        context.insert(second)
        context.insert(TranscriptVersion(text: "Važan sačuvani tekst", recording: first))
        try context.save()
        try LongRecordingService(store: store).deleteAudio(for: first, context: context)
        XCTAssertNil(first.masterRelativePath)
        XCTAssertEqual(first.stateRaw, "audioDeleted")
        XCTAssertEqual(first.transcripts.first?.text, "Važan sačuvani tekst")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: manifest.masterRelativePath).path))
        XCTAssertEqual(try Data(contentsOf: store.url(for: otherManifest.masterRelativePath)), Data([4, 5, 6]))
    }

    private func writeSilentCAF(to url: URL, seconds: Int) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<16_000 { channel[index] = 0 }
        for _ in 0..<seconds { try file.write(from: buffer) }
    }
}
