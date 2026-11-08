import XCTest
import SwiftData
@testable import ArhitektOffice

@MainActor final class AIIntegrationTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([Project.self, ProjectTask.self, ProjectIssue.self, ProjectNote.self, PhaseChange.self,
                             RecordingSession.self, AudioSegment.self, TranscriptVersion.self, MemoryEntry.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    func testEvidenceUsesExactVersionAndUTF16IncludingEmoji() throws {
        let transcript = TranscriptVersion(text: "Kuća 🏠. Trebam nazvati geodeta.")
        let ns = transcript.text as NSString
        let range = ns.range(of: "Trebam nazvati geodeta.")
        let evidence = EvidenceReference(transcriptID: transcript.id, startUTF16: range.location,
            endUTF16: NSMaxRange(range), quote: "Trebam nazvati geodeta.")
        XCTAssertNoThrow(try evidence.validate(in: transcript))
        let revised = TranscriptVersion(text: transcript.text)
        XCTAssertThrowsError(try evidence.validate(in: revised))
        var invalid = evidence
        invalid.quote = "Nešto što nije rečeno"
        XCTAssertThrowsError(try invalid.validate(in: transcript))
    }

    func testRetrievalSelectsRelevantSourcesWithoutSendingAllProjects() throws {
        let container = try container()
        let context = container.mainContext
        let first = Project(name: "Kuća Cerje")
        let second = Project(name: "Kuća Petrinja")
        context.insert(first); context.insert(second)
        let relevant = ProjectNote(text: "Investitor čeka geodeta za novu garažu.", project: first)
        context.insert(relevant)
        let unrelated = ProjectNote(text: "Boja fasade je bijela.", project: second)
        context.insert(unrelated)
        try context.save()
        let result = try LocalMemorySearch.records(context: context, query: "Koji projekti čekaju geodeta?")
        XCTAssertTrue(result.contains { $0.id == relevant.id })
        XCTAssertFalse(result.contains { $0.id == unrelated.id })
        XCTAssertTrue(result.allSatisfy { $0.recordType == "note" })
    }

    func testLongTranscriptRetrievalReturnsBoundedPreviewAndRetainsFullSource() throws {
        let container = try container()
        let context = container.mainContext
        let session = RecordingSession(title: "Dugi sastanak")
        context.insert(session)
        let full = String(repeating: "Razgovor o projektu i dogovorima. ", count: 2_000) + " Geodet šalje podlogu."
        let transcript = TranscriptVersion(text: full, recording: session)
        context.insert(transcript)
        try context.save()
        let result = try LocalMemorySearch.records(context: context, query: "geodet", limit: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].text.contains("Geodet"))
        XCTAssertLessThan(result[0].text.utf16.count, 1_700)
        XCTAssertEqual(transcript.text, full)
    }

    func testNoRelevantContextProducesExplicitInsufficientAnswerWithoutLoadingModel() async throws {
        let response = try await LocalAIClient().ask(question: "Što je dogovoreno?", context: [])
        XCTAssertTrue(response.insufficientData)
        XCTAssertTrue(response.sourceIDs.isEmpty)
    }
}
