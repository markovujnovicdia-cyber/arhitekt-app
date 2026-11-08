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

    func testWhisperWindowsCoverLongAudioWithoutGapsAndUseBoundedMemory() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let journal = try store.createManifest(id: UUID(), title: "Lokalni dugi transkript", projectID: nil)
        let master = try store.url(for: journal.masterRelativePath)
        try writeSilentCAF(to: master, seconds: 121)
        let reader = try LocalAudioReader(url: master)
        let windows = try reader.planWindows()
        XCTAssertGreaterThan(windows.count, 4)
        XCTAssertEqual(windows.first?.ownedStartFrame, 0)
        XCTAssertEqual(windows.last?.endFrame, reader.sourceFrameCount)
        XCTAssertEqual(windows.reduce(0) { $0 + $1.ownedDuration }, 121, accuracy: 0.001)
        for (index, window) in windows.enumerated() {
            XCTAssertLessThanOrEqual(window.duration, 30.001)
            XCTAssertLessThanOrEqual(window.leftContextDuration, 1.001)
            if index > 0 { XCTAssertEqual(window.ownedStartFrame, windows[index - 1].endFrame) }
            let samples = try reader.samples(for: window)
            XCTAssertLessThanOrEqual(samples.count, 480_016)
            XCTAssertEqual(Double(samples.count) / 16_000, window.duration, accuracy: 0.001)
            XCTAssertTrue(samples.allSatisfy(\.isFinite))
        }
    }

    func testWhisperInputConvertsStereo44100ToMono16000() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let journal = try store.createManifest(id: UUID(), title: "Pretvorba", projectID: nil)
        let master = try store.url(for: journal.masterRelativePath)
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
            let file = try AVAudioFile(forWriting: master, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            buffer.frameLength = 44_100
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for index in 0..<44_100 { channels[0][index] = 0.25; channels[1][index] = 0.75 }
            try file.write(from: buffer)
            try file.write(from: buffer)
        }
        let reader = try LocalAudioReader(url: master)
        let window = try XCTUnwrap(reader.planWindows().first)
        let samples = try reader.samples(for: window)
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 4)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(samples.reduce(0, +), 1)
    }

    func testSeamTrimmingUsesTimecodesAndPreservesRealRepeatedWords() throws {
        let window = LocalAudioReader.Window(index: 1, sourceStartFrame: 0,
            ownedStartFrame: 16_000, endFrame: 160_000, sourceSampleRate: 16_000)
        let segments: [(start: Double, end: Double, text: String)] = [
            (0, 0.6, "Prethodni dio."),
            (0.8, 1.6, " Ponovi."),
            (1.6, 2.4, " Ponovi."),
            (2.4, 4.0, " Novi dogovor.")
        ]
        let text = try LocalAudioReader.retainedText(segments: segments, fallback: "", window: window)
        XCTAssertEqual(text, "Ponovi. Ponovi. Novi dogovor.")
        XCTAssertFalse(text.contains("Prethodni"))
        XCTAssertEqual(try LocalAudioReader.retainedText(segments: [], fallback: "ponovi ponovi", window: window), "ponovi ponovi")
        XCTAssertThrowsError(try LocalAudioReader.retainedText(segments: [(0, .infinity, "Nevaljano")], fallback: "", window: window))
    }

    func testLocalCheckpointResumesCompletedWindowsAndRejectsOtherModelOrSource() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let id = UUID()
        let journal = try store.createManifest(id: id, title: "Nastavak", projectID: nil)
        let master = try store.url(for: journal.masterRelativePath)
        try writeSilentCAF(to: master, seconds: 61)
        let reader = try LocalAudioReader(url: master)
        let windows = try reader.planWindows()
        var checkpoint = LocalTranscriptionCheckpoint(recordingID: id, modelFingerprint: "whisper-small-verified-hash",
            source: reader.fingerprint, windows: windows.map { .init(window: $0) })
        checkpoint.windows[0].completed = true
        checkpoint.windows[0].text = "Potpun prvi dio."
        let checkpoints = LocalTranscriptionCheckpointStore(files: store)
        try checkpoints.save(checkpoint)
        let restored = try XCTUnwrap(checkpoints.load(recordingID: id))
        XCTAssertTrue(restored.windows[0].completed)
        XCTAssertEqual(restored.windows[0].text, "Potpun prvi dio.")
        XCTAssertFalse(restored.windows[1].completed)
        XCTAssertTrue(restored.matches(recordingID: id, modelFingerprint: "whisper-small-verified-hash", source: reader.fingerprint))
        XCTAssertFalse(restored.matches(recordingID: id, modelFingerprint: "cloud", source: reader.fingerprint))
        XCTAssertFalse(restored.matches(recordingID: id, modelFingerprint: "whisper-medium-verified-hash", source: reader.fingerprint))
        var changedSource = reader.fingerprint
        changedSource.byteCount += 1
        XCTAssertFalse(restored.matches(recordingID: id, modelFingerprint: "whisper-small-verified-hash", source: changedSource))
        var invalid = restored
        invalid.windows[1].window.ownedStartFrame += 1
        XCTAssertThrowsError(try checkpoints.save(invalid))
        XCTAssertEqual(try checkpoints.load(recordingID: id)?.windows[0].text, "Potpun prvi dio.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: master.path))
    }

    func testAudioDeletionRetainsCheckpointHistoryAndUnknownUserFiles() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let id = UUID()
        let journal = try store.createManifest(id: id, title: "Samo brisanje zvuka", projectID: nil)
        try Data([1, 2]).write(to: store.url(for: journal.masterRelativePath))
        let checkpointPath = "\(id.uuidString)/local-transcription-v1.json"
        let historyPath = "\(id.uuidString)/local-transcription-history-\(UUID().uuidString).json"
        let checkpoint = Data("partial checkpoint text, intentionally unreadable".utf8)
        let history = Data("diagnostic history must survive".utf8)
        try checkpoint.write(to: store.url(for: checkpointPath))
        try history.write(to: store.url(for: historyPath))
        let chunks = try store.url(for: "\(id.uuidString)/chunks")
        try store.createProtectedDirectory(chunks)
        let canonicalChunk = try store.url(for: store.segmentPath(for: id, index: 0))
        try Data([3]).write(to: canonicalChunk)
        let temporary = chunks.appendingPathComponent("export-\(UUID().uuidString).m4a")
        try Data([4]).write(to: temporary)
        let unknown = chunks.appendingPathComponent("moj-dokument.txt")
        try Data("korisnički sadržaj".utf8).write(to: unknown)
        try store.deleteAudio(id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: journal.masterRelativePath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalChunk.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: "\(id.uuidString)/recovery.json").path))
        XCTAssertEqual(try Data(contentsOf: store.url(for: checkpointPath)), checkpoint)
        XCTAssertEqual(try Data(contentsOf: store.url(for: historyPath)), history)
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "korisnički sadržaj")
        XCTAssertTrue(try store.scanRecoveryManifests().manifests.isEmpty)
        XCTAssertTrue(try store.scanRecoveryManifests().warnings.isEmpty)
        // Repeat deletion is harmless, and does not clear retained text.
        try store.deleteAudio(id: id)
        XCTAssertEqual(try Data(contentsOf: store.url(for: checkpointPath)), checkpoint)
    }

    func testDeletingAudioPromotesCheckpointTextAheadOfDatabaseToPartialRevision() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let container = try container()
        let context = container.mainContext
        let session = RecordingSession(title: "Oporavak prije brisanja")
        let journal = try store.createManifest(id: session.id, title: session.title, projectID: nil)
        let master = try store.url(for: journal.masterRelativePath)
        try writeSilentCAF(to: master, seconds: 61)
        session.masterRelativePath = journal.masterRelativePath
        context.insert(session)
        try context.save()
        let reader = try LocalAudioReader(url: master)
        var checkpoint = LocalTranscriptionCheckpoint(recordingID: session.id, modelFingerprint: "verified-model",
            source: reader.fingerprint, windows: try reader.planWindows().map { .init(window: $0) })
        checkpoint.windows[0].text = "Geodet šalje podlogu u petak."
        checkpoint.windows[0].completed = true
        let checkpoints = LocalTranscriptionCheckpointStore(files: store)
        try checkpoints.save(checkpoint)
        try LongRecordingService(store: store).deleteAudio(for: session, context: context)
        XCTAssertEqual(session.stateRaw, "audioDeleted")
        XCTAssertNil(session.masterRelativePath)
        let recovered = try XCTUnwrap(session.latestTranscript)
        XCTAssertEqual(recovered.provider, "oporavljeni-djelomični-local")
        XCTAssertTrue(recovered.text.contains("DJELOMIČNI"))
        XCTAssertTrue(recovered.text.contains("Geodet šalje podlogu u petak."))
        XCTAssertTrue(recovered.text.contains("nije transkribiran"))
        XCTAssertEqual(try checkpoints.load(recordingID: session.id)?.windows[0].text, checkpoint.windows[0].text)
    }

    func testStaleRecoveryManifestCannotResurrectExplicitlyDeletedAudio() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let container = try container()
        let context = container.mainContext
        let session = RecordingSession(title: "Već izbrisani zvuk")
        session.stateRaw = "audioDeleted"
        session.masterRelativePath = nil
        context.insert(session)
        try context.save()
        _ = try store.createManifest(id: session.id, title: session.title, projectID: nil)
        _ = try LongRecordingService(store: store).recoverSessions(context: context)
        XCTAssertNil(session.masterRelativePath)
        XCTAssertEqual(session.stateRaw, "audioDeleted")
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
