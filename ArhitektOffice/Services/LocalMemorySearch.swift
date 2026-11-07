import Foundation
import SwiftData

/// Bounded lexical retrieval runs entirely on-device. It never sends a database
/// dump: callers preview the selected excerpts and request consent before upload.
@MainActor enum LocalMemorySearch {
    static func records(context: ModelContext, query: String, projectID: UUID? = nil, limit: Int = 20) throws -> [AIContextRecord] {
        var candidates: [AIContextRecord] = []
        for note in try context.fetch(FetchDescriptor<ProjectNote>()) {
            candidates.append(AIContextRecord(recordType: "note", id: note.id, projectID: note.project?.id, date: note.createdAt,
                title: "\(note.project?.name ?? "Projekt") · Bilješka", text: note.text))
        }
        for entry in try context.fetch(FetchDescriptor<MemoryEntry>()) {
            let person = entry.responsible.map { "\nOdgovoran: \($0)" } ?? ""
            let due = entry.dueDate.map { "\nRok: \($0.formatted(.iso8601.year().month().day()))" } ?? ""
            candidates.append(AIContextRecord(recordType: "memory", id: entry.id, projectID: entry.project?.id, date: entry.createdAt,
                title: "\(entry.project?.name ?? "Projekt") · \(entry.kind.label) · \(entry.title)",
                text: "Status tvrdnje: \(entry.certainty.label)\n\(entry.details)\(person)\(due)\nIzvor: \(entry.quote)"))
        }
        for transcript in try context.fetch(FetchDescriptor<TranscriptVersion>()) {
            candidates.append(AIContextRecord(recordType: "transcript", id: transcript.id, projectID: transcript.recording?.project?.id,
                date: transcript.createdAt,
                title: "\(transcript.recording?.project?.name ?? "Nerazvrstano") · \(transcript.recording?.title ?? "Transkript") · verzija \(transcript.revision)", text: transcript.text))
        }
        // Include manual tasks/issues as sources, not just derived AI entries.
        for task in try context.fetch(FetchDescriptor<ProjectTask>()) {
            candidates.append(AIContextRecord(recordType: "task", id: task.id, projectID: task.project?.id, date: task.createdAt,
                title: "\(task.project?.name ?? "Projekt") · Zadatak · \(task.title)",
                text: "\(task.details)\nStatus: \(task.status.rawValue)\nPrioritet: \(task.priority.rawValue)\nRok: \(task.dueDate.map { $0.formatted(.iso8601.year().month().day()) } ?? "nije naveden")\nOdgovoran: \(task.responsible ?? "nije navedeno")"))
        }
        for issue in try context.fetch(FetchDescriptor<ProjectIssue>()) {
            candidates.append(AIContextRecord(recordType: "issue", id: issue.id, projectID: issue.project?.id, date: issue.createdAt,
                title: "\(issue.project?.name ?? "Projekt") · Problem · \(issue.title)",
                text: "\(issue.details)\nStatus: \(issue.status.rawValue)\nRješenje: \(issue.resolution)"))
        }
        let words = tokens(query)
        let interval = dateInterval(for: query)
        let ranked = candidates.filter { record in
            (projectID == nil || record.projectID == projectID) && (interval?.contains(record.date) ?? true)
        }.compactMap { record -> (AIContextRecord, Int)? in
            let haystack = normalized(record.title + " " + record.text)
            let matches = words.filter { haystack.contains($0) }.count
            guard words.isEmpty || matches > 0 else { return nil }
            return (record, matches)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.date > rhs.0.date : lhs.1 > rhs.1
        }
        var budget = 28_000
        var result: [AIContextRecord] = []
        for (var record, _) in ranked.prefix(max(0, min(limit, 30))) {
            let excerpt = excerpt(record.text, words: words, maximum: min(1_600, budget))
            guard !excerpt.isEmpty, budget >= excerpt.utf16.count else { break }
            record.text = excerpt
            budget -= excerpt.utf16.count
            result.append(record)
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "hr_HR")).lowercased()
    }
    private static func tokens(_ query: String) -> [String] {
        let stop: Set<String> = ["sto", "sam", "smo", "koji", "koje", "kako", "jos", "trebam", "posljednji", "put", "trenutno", "tijekom", "vremena", "prosli", "tjedan", "danas", "jucer", "projekt", "projekti", "projekta"]
        return normalized(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 && !stop.contains($0) }.map { String($0.prefix(4)) }
    }
    private static func excerpt(_ text: String, words: [String], maximum: Int) -> String {
        guard maximum > 0 else { return "" }
        let ns = text as NSString
        guard ns.length > maximum else { return text }
        // NSString case/diacritic search preserves source UTF16 positions.
        let match = words.compactMap { word -> NSRange? in
            let range = ns.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
            return range.location == NSNotFound ? nil : range
        }.first
        let start = max(0, min((match?.location ?? 0) - 200, ns.length - maximum))
        let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: maximum))
        return ns.substring(with: range)
    }
    private static func dateInterval(for query: String) -> DateInterval? {
        let text = normalized(query)
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        if text.contains("prosli tjedan"), let week = calendar.dateInterval(of: .weekOfYear, for: today),
           let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start) {
            return DateInterval(start: previous, end: week.start.addingTimeInterval(-0.001))
        }
        if text.contains("jucer"), let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            return DateInterval(start: yesterday, end: today.addingTimeInterval(-0.001))
        }
        if text.contains("danas"), let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
            return DateInterval(start: today, end: tomorrow.addingTimeInterval(-0.001))
        }
        return nil
    }
}
