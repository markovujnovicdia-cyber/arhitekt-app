import XCTest
import SwiftData
@testable import ArhitektOffice

@MainActor final class FTSIndexTests: XCTestCase {
    private func index() throws -> FTSIndex {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try FTSIndex(url: directory.appendingPathComponent("search.sqlite"))
    }
    private func source(id: UUID = UUID(), projectID: UUID? = nil, type: String = "note", title: String = "Cerje",
                        text: String, created: Date = Date(), due: Date? = nil, status: String? = nil) -> FTSSource {
        FTSSource(id: id, recordType: type, projectID: projectID, date: created, dueDate: due, status: status, title: title, text: text)
    }
    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }

    func testCroatianDiacriticsAndMorphologicalPrefixUseRealFTS5() throws {
        let index = try index()
        let relevant = source(text: "Čakovec: investitor čeka geodeta za kuću i garažu.")
        let unrelated = source(text: "Fasada je bijela.")
        try index.reconcile([relevant, unrelated])
        XCTAssertEqual(try index.search(query: "cakovecki geodet").map { $0.source.id }, [relevant.id])
        XCTAssertEqual(try index.search(query: "garaža").first?.source.id, relevant.id)
    }

    func testBM25PrefersRelevantTitleWithoutDuplicatingSourceUUID() throws {
        let index = try index()
        let best = source(title: "Geodet", text: "Geodet šalje podlogu.")
        let weak = source(title: "Sastanak", text: String(repeating: "Dugi razgovor o krovu. ", count: 500) + "Geodet.")
        try index.reconcile([weak, best])
        let result = try index.search(query: "geodet")
        XCTAssertEqual(result.first?.source.id, best.id)
        XCTAssertEqual(Set(result.map { $0.source.id }).count, result.count)
    }

    func testEmbeddedNullCannotTruncateIndexedSourceOrEvidence() throws {
        let index = try index()
        let original = source(text: "Početak\u{0000}Hidroizolacija nakon posebnog znaka.")
        try index.reconcile([original])
        let result = try XCTUnwrap(index.search(query: "hidroizolacija").first)
        XCTAssertEqual(result.source.text, original.text)
        XCTAssertEqual(result.endUTF16, original.text.utf16.count)
    }

    func testAllLongTranscriptCharactersIndexedAndTailEvidenceOffsetsExact() throws {
        let index = try index()
        let text = String(repeating: "Razgovor o projektu 🏠 i svim dogovorima. ", count: 2_000) + "Posebni završni termin: hidroizolacija podruma."
        let original = source(type: "transcript", text: text)
        try index.reconcile([original])
        let found = try XCTUnwrap(index.search(query: "hidroizolacija").first)
        XCTAssertEqual(found.source.id, original.id)
        XCTAssertTrue(found.source.text.contains("hidroizolacija"))
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: found.startUTF16, length: found.endUTF16 - found.startUTF16)), found.source.text)
        var covered = Array(repeating: false, count: text.utf16.count)
        for range in FTSIndex.chunkRanges(in: text) {
            XCTAssertNotNil(Range(range, in: text))
            for offset in range.location..<NSMaxRange(range) { covered[offset] = true }
        }
        XCTAssertTrue(covered.allSatisfy { $0 })
    }

    func testRestoringOlderSnapshotRemovesStaleRowsAndReindexesSameUUID() throws {
        let index = try index()
        let stableID = UUID()
        let current = source(id: stableID, text: "Nova odluka: aluminijska stolarija.")
        let removed = source(text: "Zapis koji ne postoji u vraćenoj bazi.")
        try index.reconcile([current, removed])
        XCTAssertEqual(try index.search(query: "aluminijska").count, 1)
        let restored = source(id: stableID, text: "Stari dogovor: drvena stolarija.")
        try index.reconcile([restored])
        XCTAssertTrue(try index.search(query: "aluminijska").isEmpty)
        XCTAssertTrue(try index.search(query: "vracenoj").isEmpty)
        XCTAssertEqual(try index.search(query: "drvena").map { $0.source.id }, [stableID])
    }

    func testMaliciousMatchAndProjectStringsCannotChangeSchemaOrLeakOtherProject() throws {
        let index = try index()
        let first = UUID(); let second = UUID()
        let relevant = source(projectID: first, text: "Geodet čeka podlogu.")
        let privateOther = source(projectID: second, text: "Geodet drugog projekta.")
        try index.reconcile([relevant, privateOther])
        _ = try index.search(query: #"geodet" OR 1=1; DROP TABLE documents; --"#, projectID: first)
        let normal = try index.search(query: "geodet", projectID: first)
        XCTAssertEqual(normal.map { $0.source.id }, [relevant.id])
        XCTAssertFalse(FTSIndex.matchExpression(#"" OR * NEAR(foo)"#).contains("NEAR("))
        try index.reconcile([relevant])
        XCTAssertEqual(try index.search(query: "geodet").count, 1)
    }

    func testUnresolvedThisWeekUsesDueDateForTasksAndExcludesResolvedHistory() throws {
        let index = try index()
        let now = date("2026-11-11T12:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zagreb")!
        let due = date("2026-11-12T12:00:00Z")
        let old = date("2026-10-01T12:00:00Z")
        let task = source(type: "task", text: "Nazvati geodeta", created: old, due: due, status: "open")
        let overdueDifferentWeek = source(type: "task", text: "Stari rok", created: now, due: old, status: "open")
        let completed = source(type: "task", text: "Već izvršeno", created: now, due: due, status: "closed")
        let openIssue = source(type: "issue", text: "Nedostaje dokument", created: now, status: "open")
        let resolved = source(type: "issue", text: "Problem je riješen", created: now, status: "closed")
        let history = source(type: "transcript", text: "Ovaj problem još nisam riješio", created: now)
        let query = "Što još nisam riješio ovaj tjedan?"
        let result = try LocalMemorySearch.indexedRecords(sources: [task, overdueDifferentWeek, completed, openIssue, resolved, history],
            query: query, index: index, now: now, calendar: calendar)
        XCTAssertEqual(Set(result.map(\.id)), [task.id, openIssue.id])
    }

    func testMentionedLastWeekUsesCreationDateRatherThanDeadline() throws {
        let index = try index()
        let now = date("2026-11-11T12:00:00Z")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let lastWeek = date("2026-11-04T12:00:00Z")
        let mentioned = source(type: "task", text: "Nazvati statičara", created: lastWeek, due: now, status: "open")
        let dueLastWeek = source(type: "task", text: "Nazvati geodeta", created: now, due: lastWeek, status: "open")
        let query = "Koje sam zadatke spomenuo prošli tjedan?"
        let result = try LocalMemorySearch.indexedRecords(sources: [mentioned, dueLastWeek], query: query, index: index, now: now, calendar: calendar)
        XCTAssertEqual(result.map(\.id), [mentioned.id])
    }

    func testDuplicateInputCannotCorruptAlreadyCommittedIndex() throws {
        let index = try index()
        let original = source(text: "Sačuvani izvor o geodetu.")
        try index.reconcile([original])
        var duplicate = original; duplicate.text = "Druga verzija istog identifikatora."
        XCTAssertThrowsError(try index.reconcile([original, duplicate]))
        XCTAssertEqual(try index.search(query: "sacuvani").first?.source.text, original.text)
    }

    func testIndexSurvivesCloseAndReopenAndPromptContextIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("search.sqlite")
        let sources = (0..<20).map { source(title: "Projekt \($0)", text: String(repeating: "Geodet šalje podatke. ", count: 500)) }
        var first: FTSIndex? = try FTSIndex(url: url)
        try first?.reconcile(sources)
        first = nil
        let reopened = try FTSIndex(url: url)
        XCTAssertEqual(try reopened.search(query: "geodet").count, 20)
        let context = try LocalMemorySearch.indexedRecords(sources: sources, query: "geodet", index: reopened)
        XCTAssertFalse(context.isEmpty)
        XCTAssertLessThanOrEqual(context.reduce(0) { $0 + $1.text.utf16.count + $1.title.utf16.count + 180 }, LocalMemorySearch.contextBudgetUTF16)
        XCTAssertTrue(context.allSatisfy { $0.sourceStartUTF16 != nil && $0.sourceEndUTF16 != nil })
    }

    func testAsyncRetrievalMatchesSyncCitationsAndReconcilesEditedSource() async throws {
        let schema = Schema([Project.self, ProjectTask.self, ProjectIssue.self, ProjectNote.self, PhaseChange.self,
                             RecordingSession.self, AudioSegment.self, TranscriptVersion.self, MemoryEntry.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = container.mainContext
        let project = Project(name: "Cerje"); context.insert(project)
        let note = ProjectNote(text: String(repeating: "Dugi sastanak o gradnji. ", count: 1_000) + "Geodet šalje podlogu.", project: project)
        context.insert(note); try context.save()
        let synchronous = try LocalMemorySearch.records(context: context, query: "geodet", projectID: project.id)
        let asynchronous = try await LocalMemorySearch.recordsAsync(context: context, query: "geodet", projectID: project.id)
        XCTAssertEqual(asynchronous, synchronous)
        XCTAssertEqual(asynchronous.first?.id, note.id)
        XCTAssertTrue(asynchronous.first?.text.contains("Geodet") ?? false)
        note.text = "Statičar je preuzeo novi zadatak."; try context.save()
        let stale = try await LocalMemorySearch.recordsAsync(context: context, query: "geodet", projectID: project.id)
        XCTAssertTrue(stale.isEmpty)
        let changed = try await LocalMemorySearch.recordsAsync(context: context, query: "statičar", projectID: project.id)
        XCTAssertEqual(changed.first?.id, note.id)
    }
}
