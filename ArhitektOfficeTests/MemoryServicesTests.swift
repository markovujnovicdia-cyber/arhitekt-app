import XCTest
import SwiftData
@testable import ArhitektOffice

@MainActor final class MemoryServicesTests: XCTestCase {
    private var schema: Schema {
        Schema([Project.self, ProjectTask.self, ProjectIssue.self, ProjectNote.self, PhaseChange.self,
                RecordingSession.self, AudioSegment.self, TranscriptVersion.self, MemoryEntry.self])
    }
    private func container() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    private func proposal(_ version: TranscriptVersion, project: Project, kind: MemoryKind = .task) -> MemoryProposal {
        MemoryProposal(id: UUID(), projectID: project.id, kind: kind, certainty: .planned,
                       title: "Nazvati geodeta", details: "Provjeriti podlogu", responsible: "Arhitekt", dueDate: "2026-11-20",
                       source: EvidenceReference(transcriptID: version.id, startUTF16: 0, endUTF16: version.text.utf16.count, quote: version.text),
                       relatedEntryID: nil)
    }

    func testCorrectionCreatesNewVersionAndOldEvidenceRemainsValid() throws {
        let store = try container(); let context = store.mainContext
        let project = Project(name: "Cerje"); context.insert(project)
        let recording = RecordingSession(title: "Sastanak", project: project); context.insert(recording)
        let original = try MemoryStore.appendTranscript(text: "Trebam nazvati geodeta.", to: recording, context: context)
        _ = try MemoryStore.confirm(proposals: [proposal(original, project: project)], transcript: original, context: context)
        let corrected = try MemoryStore.appendTranscript(text: "Trebam nazvati statičara, a ne geodeta.", to: recording, context: context)
        XCTAssertEqual(recording.transcripts.count, 2)
        XCTAssertEqual(original.text, "Trebam nazvati geodeta.")
        XCTAssertEqual(corrected.revision, 2)
        XCTAssertEqual(corrected.supersedesID, original.id)
        let memory = try XCTUnwrap(context.fetch(FetchDescriptor<MemoryEntry>()).first)
        XCTAssertEqual(memory.transcript?.id, original.id)
        XCTAssertEqual(memory.quote, original.text)
        try MemoryStore.validateEvidence(proposal(original, project: project).source, in: original)
        XCTAssertThrowsError(try MemoryStore.validateEvidence(proposal(original, project: project).source, in: corrected))
    }

    func testRepeatedConfirmationAndEquivalentRevisionDoNotDuplicateTask() throws {
        let store = try container(); let context = store.mainContext
        let project = Project(name: "Cerje"); context.insert(project)
        let recording = RecordingSession(title: "Dogovor", project: project); context.insert(recording)
        let first = try MemoryStore.appendTranscript(text: "Trebam nazvati geodeta.", to: recording, context: context)
        let proposed = proposal(first, project: project)
        let accepted = try MemoryStore.confirm(proposals: [proposed, proposed], transcript: first, context: context)
        XCTAssertEqual(accepted.insertedCount, 1)
        XCTAssertEqual(accepted.skippedCount, 1)
        let repeated = try MemoryStore.confirm(proposals: [proposed], transcript: first, context: context)
        XCTAssertEqual(repeated.insertedCount, 0)
        XCTAssertEqual(repeated.skippedCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectTask>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryEntry>()), 1)
        XCTAssertEqual(project.tasks.first?.responsible, "Arhitekt")
        XCTAssertNotNil(project.tasks.first?.sourceMemoryID)
    }

    func testOneInvalidProposalCannotPartlyCommitOtherValidProposals() throws {
        let store = try container(); let context = store.mainContext
        let project = Project(name: "Cerje"); context.insert(project)
        let recording = RecordingSession(title: "Dogovor", project: project); context.insert(recording)
        let version = try MemoryStore.appendTranscript(text: "Trebam nazvati geodeta.", to: recording, context: context)
        let valid = proposal(version, project: project)
        var fabricated = valid; fabricated.id = UUID(); fabricated.source.quote = "Izmišljeni sadržaj"
        XCTAssertThrowsError(try MemoryStore.confirm(proposals: [valid, fabricated], transcript: version, context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectTask>()), 0)
        XCTAssertEqual(recording.transcripts.first?.text, version.text)
    }

    func testUTF16EvidenceCannotSplitEmojiOrPointAtDifferentTranscript() throws {
        let version = TranscriptVersion(text: "😀 Dogovor o geodetu.")
        let split = EvidenceReference(transcriptID: version.id, startUTF16: 1, endUTF16: 2, quote: "�")
        XCTAssertThrowsError(try MemoryStore.validateEvidence(split, in: version))
        let valid = EvidenceReference(transcriptID: version.id, startUTF16: 0, endUTF16: 2, quote: "😀")
        XCTAssertNoThrow(try MemoryStore.validateEvidence(valid, in: version))
        let foreign = EvidenceReference(transcriptID: UUID(), startUTF16: 0, endUTF16: 2, quote: "😀")
        XCTAssertThrowsError(try MemoryStore.validateEvidence(foreign, in: version))
    }

    func testUncertainDecisionIsPreservedWithoutFabricatingTaskAndRequiresProject() throws {
        let store = try container(); let context = store.mainContext
        let project = Project(name: "Cerje"); context.insert(project)
        let recording = RecordingSession(title: "Razgovor"); context.insert(recording)
        let version = try MemoryStore.appendTranscript(text: "Možda ćemo smanjiti garažu.", to: recording, context: context)
        var item = proposal(version, project: project, kind: .decision)
        item.title = "Moguće smanjenje garaže"; item.certainty = .uncertain; item.dueDate = nil; item.responsible = nil
        item.projectID = nil
        XCTAssertThrowsError(try MemoryStore.confirm(proposals: [item], transcript: version, context: context))
        item.projectID = project.id
        _ = try MemoryStore.confirm(proposals: [item], transcript: version, context: context)
        XCTAssertEqual(project.memory.first?.certainty, .uncertain)
        XCTAssertNil(project.memory.first?.dueDate)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectTask>()), 0)
    }

    func testExplicitDateValidationDoesNotInventOrNormalizeImpossibleDates() throws {
        XCTAssertNoThrow(try MemoryStore.parseDate("2028-02-29"))
        XCTAssertThrowsError(try MemoryStore.parseDate("2027-02-29"))
        XCTAssertThrowsError(try MemoryStore.parseDate("sljedeći petak"))
        XCTAssertThrowsError(try MemoryStore.parseDate("2026-13-01"))
    }

    func testV1BackupStillImportsWithoutDiscardingNewRecordingHistory() throws {
        let store = try container(); let context = store.mainContext
        let project = Project(name: "Stari projekt"); context.insert(project)
        let recording = RecordingSession(title: "Duga snimka", project: project); context.insert(recording)
        let version = try MemoryStore.appendTranscript(text: "Izvorni zapis ostaje.", to: recording, context: context)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BackupService.export(context: context)) as? [String: Any])
        json["version"] = 1
        for key in ["recordings", "segments", "transcripts", "memory"] { json.removeValue(forKey: key) }
        _ = try BackupService.importData(JSONSerialization.data(withJSONObject: json), into: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordingSession>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TranscriptVersion>()), 1)
        XCTAssertEqual(recording.latestTranscript?.id, version.id)
    }

    func testV2MetadataRoundTripKeepsUnassignedRecordingAndAllRevisions() throws {
        let source = try container(); let context = source.mainContext
        let recording = RecordingSession(title: "Neodređeni projekt"); context.insert(recording)
        recording.masterRelativePath = "\(recording.id.uuidString)/master.m4a"
        recording.duration = 1_800
        for index in 0..<30 {
            context.insert(AudioSegment(index: index, relativePath: "\(recording.id.uuidString)/part-\(index).m4a", duration: 60, session: recording))
        }
        _ = try MemoryStore.appendTranscript(text: "Izvorna duga priča.", to: recording, context: context)
        _ = try MemoryStore.appendTranscript(text: "Ispravljena duga priča.", to: recording, context: context)
        let data = try BackupService.export(context: context)
        XCTAssertEqual(try BackupService.audioRelativePaths(in: data).count, 31)
        let target = try container()
        _ = try BackupService.importData(data, into: target.mainContext)
        _ = try BackupService.importData(data, into: target.mainContext)
        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<RecordingSession>()).first)
        XCTAssertNil(restored.project)
        XCTAssertEqual(restored.duration, 1_800)
        XCTAssertEqual(restored.segments.count, 30)
        XCTAssertEqual(restored.segments.map(\.index), Array(0..<30))
        XCTAssertEqual(restored.transcripts.map(\.text), ["Izvorna duga priča.", "Ispravljena duga priča."])
    }

    func testImportCannotOverwriteAnImmutableTranscriptOrAcceptPathTraversal() throws {
        let store = try container(); let context = store.mainContext
        let recording = RecordingSession(title: "Izvor"); context.insert(recording)
        recording.masterRelativePath = "\(recording.id.uuidString)/master.m4a"
        let version = try MemoryStore.appendTranscript(text: "Original koji se čuva.", to: recording, context: context)
        let original = try BackupService.export(context: context)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var versions = try XCTUnwrap(json["transcripts"] as? [[String: Any]])
        versions[0]["text"] = "Zamjenski tekst"; json["transcripts"] = versions
        XCTAssertThrowsError(try BackupService.importData(JSONSerialization.data(withJSONObject: json), into: context))
        XCTAssertEqual(version.text, "Original koji se čuva.")
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var recordings = try XCTUnwrap(json["recordings"] as? [[String: Any]])
        recordings[0]["masterRelativePath"] = "../../outside.m4a"; json["recordings"] = recordings
        XCTAssertThrowsError(try BackupService.validate(data: JSONSerialization.data(withJSONObject: json)))
    }

    func testLongSessionAndRevisionHistorySurvivePersistentStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("memory.store"), cloudKitDatabase: .none)
        let sessionID: UUID
        do {
            let store = try ModelContainer(for: schema, configurations: [config]); let context = store.mainContext
            let recording = RecordingSession(title: "41 minuta sastanka"); context.insert(recording)
            sessionID = recording.id; recording.duration = 2_460; recording.stateRaw = "interrupted"
            for index in 0..<41 {
                context.insert(AudioSegment(index: index, relativePath: "\(sessionID)/\(index).m4a", duration: 60, session: recording))
            }
            let complete = (0..<41).map { "Dio \($0): važan dogovor i svi njegovi detalji." }.joined(separator: "\n")
            _ = try MemoryStore.appendTranscript(text: complete, to: recording, context: context)
            _ = try MemoryStore.appendTranscript(text: complete + "\nNaknadna ispravka.", to: recording, context: context)
        }
        let reopened = try ModelContainer(for: schema, configurations: [config])
        let recording = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<RecordingSession>()).first)
        XCTAssertEqual(recording.id, sessionID)
        XCTAssertEqual(recording.stateRaw, "interrupted")
        XCTAssertEqual(recording.segments.count, 41)
        XCTAssertEqual(recording.transcripts.count, 2)
        XCTAssertTrue(recording.transcripts[0].text.contains("Dio 40:"))
        XCTAssertFalse(recording.transcripts[0].text.contains("Naknadna ispravka."))
        XCTAssertTrue(recording.transcripts[1].text.contains("Naknadna ispravka."))
    }
}
