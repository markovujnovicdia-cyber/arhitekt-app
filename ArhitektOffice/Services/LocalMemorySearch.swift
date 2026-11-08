import CryptoKit
import Foundation
import SwiftData

/// SQLite FTS5 is local and derived entirely from SwiftData. All source text is
/// indexed; only bounded, relevant excerpts reach the on-device language model.
@MainActor enum LocalMemorySearch {
    static let contextBudgetUTF16 = FTSContextBuilder.contextBudgetUTF16
    private static var indexes: [String: FTSIndex] = [:]

    static func records(context: ModelContext, query: String, projectID: UUID? = nil, limit: Int = 20) throws -> [AIContextRecord] {
        let sources = try allSources(context: context)
        let index = try indexFor(context: context)
        return try indexedRecords(sources: sources, query: query, projectID: projectID, limit: limit, index: index)
    }

    /// Only the SwiftData snapshot is read on the main actor. Tokenization,
    /// hashing, SQLite writes, ranking and excerpt mapping run on a background
    /// worker with a private SQLite handle. No model object crosses actors.
    static func recordsAsync(context: ModelContext, query: String, projectID: UUID? = nil,
                             limit: Int = 20) async throws -> [AIContextRecord] {
        let sources = try allSources(context: context)
        let location = indexLocation(context: context).url
        let now = Date()
        let calendar = Calendar.current
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let index = try FTSIndex(url: location)
            return try FTSContextBuilder.records(sources: sources, query: query, projectID: projectID,
                                                  limit: limit, index: index, now: now, calendar: calendar)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    /// Injectable index and clock let tests exercise the real SQL without changing
    /// the device date or a user's persistent index.
    static func indexedRecords(sources: [FTSSource], query: String, projectID: UUID? = nil, limit: Int = 20,
                               index: FTSIndex, now: Date = Date(), calendar: Calendar = .current) throws -> [AIContextRecord] {
        try FTSContextBuilder.records(sources: sources, query: query, projectID: projectID,
                                       limit: limit, index: index, now: now, calendar: calendar)
    }

    static func allSources(context: ModelContext) throws -> [FTSSource] {
        let tasks = try context.fetch(FetchDescriptor<ProjectTask>())
        let issues = try context.fetch(FetchDescriptor<ProjectIssue>())
        var linkedTaskStatuses: [UUID: String] = [:]
        var linkedIssueStatuses: [UUID: String] = [:]
        for task in tasks { if let source = task.sourceMemoryID { linkedTaskStatuses[source] = task.status.rawValue } }
        for issue in issues { if let source = issue.sourceMemoryID { linkedIssueStatuses[source] = issue.status.rawValue } }
        var sources: [FTSSource] = []
        for note in try context.fetch(FetchDescriptor<ProjectNote>()) {
            sources.append(FTSSource(id: note.id, recordType: "note", projectID: note.project?.id, date: note.createdAt,
                title: "\(note.project?.name ?? "Projekt") · Bilješka", text: note.text))
        }
        for entry in try context.fetch(FetchDescriptor<MemoryEntry>()) {
            let person = entry.responsible.map { "\nOdgovoran: \($0)" } ?? ""
            let due = entry.dueDate.map { "\nRok: \(dateText($0))" } ?? ""
            let taskStatus = linkedTaskStatuses[entry.id].map { "\nTrenutačni status povezanog zadatka: \($0)" } ?? ""
            let issueStatus = linkedIssueStatuses[entry.id].map { "\nTrenutačni status povezanog problema: \($0)" } ?? ""
            sources.append(FTSSource(id: entry.id, recordType: "memory", projectID: entry.project?.id, date: entry.createdAt,
                dueDate: entry.dueDate,
                title: "\(entry.project?.name ?? "Projekt") · \(entry.kind.label) · \(entry.title)",
                text: "Povijesni zapis. Pouzdanost: \(entry.certainty.label)\n\(entry.details)\(person)\(due)\(taskStatus)\(issueStatus)\nIzvor: \(entry.quote)"))
        }
        for transcript in try context.fetch(FetchDescriptor<TranscriptVersion>()) {
            sources.append(FTSSource(id: transcript.id, recordType: "transcript", projectID: transcript.recording?.project?.id,
                date: transcript.createdAt,
                title: "\(transcript.recording?.project?.name ?? "Nerazvrstano") · \(transcript.recording?.title ?? "Transkript") · verzija \(transcript.revision)",
                text: transcript.text))
        }
        for task in tasks {
            sources.append(FTSSource(id: task.id, recordType: "task", projectID: task.project?.id, date: task.createdAt,
                dueDate: task.dueDate, status: task.status == .open ? "open" : "closed",
                title: "\(task.project?.name ?? "Projekt") · Zadatak · \(task.title)",
                text: "\(task.details)\nStatus: \(task.status.rawValue)\nPrioritet: \(task.priority.rawValue)\nRok: \(task.dueDate.map(dateText) ?? "nije naveden")\nOdgovoran: \(task.responsible ?? "nije navedeno")"))
        }
        for issue in issues {
            sources.append(FTSSource(id: issue.id, recordType: "issue", projectID: issue.project?.id, date: issue.createdAt,
                status: issue.status == .open ? "open" : "closed",
                title: "\(issue.project?.name ?? "Projekt") · Problem · \(issue.title)",
                text: "\(issue.details)\nStatus: \(issue.status.rawValue)\nRješenje: \(issue.resolution)"))
        }
        return sources
    }

    private static func indexFor(context: ModelContext) throws -> FTSIndex {
        let location = indexLocation(context: context)
        if let index = indexes[location.key] { return index }
        let index = try FTSIndex(url: location.url)
        indexes[location.key] = index
        return index
    }

    private static func indexLocation(context: ModelContext) -> (url: URL, key: String) {
        let sourceURL = context.container.configurations.first?.url ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("default.store")
        let key = SHA256.hash(data: Data(sourceURL.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = sourceURL.deletingLastPathComponent().appendingPathComponent("SearchIndex-\(key).sqlite")
        return (url, key)
    }

    private static func dateText(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

}

/// Plain value mapping shared by synchronous tests and detached production work.
private enum FTSContextBuilder {
    static let contextBudgetUTF16 = 6_000

    static func records(sources: [FTSSource], query: String, projectID: UUID?, limit: Int,
                        index: FTSIndex, now: Date, calendar: Calendar) throws -> [AIContextRecord] {
        try index.reconcile(sources)
        let hits = try index.search(query: query, projectID: projectID,
                                    filter: FTSQuery.filter(for: query, now: now, calendar: calendar), limit: limit)
        var remaining = contextBudgetUTF16
        var result: [AIContextRecord] = []
        for hit in hits {
            try Task.checkCancellation()
            let title = boundedTitle(hit.source.title)
            let overhead = title.utf16.count + 180
            let cost = overhead + hit.source.text.utf16.count
            guard cost <= remaining else { continue }
            remaining -= cost
            result.append(AIContextRecord(recordType: hit.source.recordType,
                                           sourceStartUTF16: hit.startUTF16, sourceEndUTF16: hit.endUTF16,
                                           id: hit.source.id, projectID: hit.source.projectID,
                                           date: hit.source.date, title: title, text: hit.source.text))
        }
        return result
    }

    private static func boundedTitle(_ title: String) -> String {
        let ns = title as NSString
        guard ns.length > 240 else { return title }
        return ns.substring(with: ns.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: 240)))
    }
}
