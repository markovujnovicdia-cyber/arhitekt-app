import CryptoKit
import Foundation
import SQLite3

struct FTSSource: Codable, Sendable {
    var id: UUID
    var recordType: String
    var projectID: UUID?
    var date: Date
    var dueDate: Date? = nil
    var status: String? = nil
    var title: String
    var text: String
}

struct FTSHit: Sendable {
    var source: FTSSource
    var startUTF16: Int
    var endUTF16: Int
    var rank: Double
}

enum FTSIndexError: LocalizedError {
    case database(String), duplicateSource
    var errorDescription: String? {
        switch self {
        case .database(let detail): "Lokalno pretraživanje nije dostupno: \(detail)"
        case .duplicateSource: "Više zapisa koristi isti identifikator. Izvorni podaci nisu promijenjeni."
        }
    }
}

struct FTSSearchFilter: Sendable {
    enum DateBasis: Sendable { case created, due, taskDueOtherwiseCreated }
    var recordTypes: [String] = []
    var status: String?
    var startDate: Date?
    var endDate: Date?
    var dateBasis: DateBasis = .created
}

/// An expendable local index, never the authoritative store. Every query first
/// reconciles against SwiftData by content fingerprint, so edits, deletion and
/// restoring an older JSON/package cannot leave stale indexed facts behind.
// Each instance is confined to its creating worker. It is intentionally not
// Sendable: async callers create their own handle instead of sharing a pointer.
final class FTSIndex {
    static let chunkLength = 1_200
    static let chunkOverlap = 240
    static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS documents(source_id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL);
    CREATE VIRTUAL TABLE IF NOT EXISTS source_fts USING fts5(
        title, body, source_id UNINDEXED, record_type UNINDEXED,
        project_id UNINDEXED, created_at UNINDEXED, due_at UNINDEXED,
        status UNINDEXED, source_start UNINDEXED, source_end UNINDEXED,
        tokenize='unicode61 remove_diacritics 2', prefix='4'
    );
    PRAGMA user_version=1;
    """

    private var database: OpaquePointer?
    private let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let result = sqlite3_open_v2(url.path, &database,
                                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite"
            if let database { sqlite3_close(database) }; database = nil
            throw FTSIndexError.database(message)
        }
        do {
            sqlite3_busy_timeout(database, 2_000)
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=FULL;")
            try execute("PRAGMA temp_store=MEMORY;")
            try executeScript(Self.schemaSQL)
            try protectFiles()
        } catch {
            if let database { sqlite3_close(database) }; database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    func reconcile(_ sources: [FTSSource]) throws {
        var seen = Set<UUID>()
        guard sources.allSatisfy({ seen.insert($0.id).inserted }) else { throw FTSIndexError.duplicateSource }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprints = try sources.map { source in
            try Task.checkCancellation()
            return (source, SHA256.hash(data: try encoder.encode(source)).map { String(format: "%02x", $0) }.joined())
        }
        try execute("BEGIN IMMEDIATE;")
        do {
            let existing = try currentFingerprints()
            let incoming = Set(sources.map { $0.id.uuidString })
            for stale in existing.keys where !incoming.contains(stale) {
                try Task.checkCancellation()
                try remove(sourceID: stale)
            }
            for (source, fingerprint) in fingerprints where existing[source.id.uuidString] != fingerprint {
                try Task.checkCancellation()
                try remove(sourceID: source.id.uuidString)
                for range in Self.chunkRanges(in: source.text) {
                    try Task.checkCancellation()
                    let body = (source.text as NSString).substring(with: range)
                    try execute("""
                    INSERT INTO source_fts(title,body,source_id,record_type,project_id,created_at,due_at,status,source_start,source_end)
                    VALUES(?,?,?,?,?,?,?,?,?,?);
                    """, [.text(source.title), .text(body), .text(source.id.uuidString), .text(source.recordType),
                           source.projectID.map { .text($0.uuidString) } ?? .null, .number(source.date.timeIntervalSince1970),
                           source.dueDate.map { .number($0.timeIntervalSince1970) } ?? .null,
                           source.status.map(Binding.text) ?? .null, .integer(range.location), .integer(NSMaxRange(range))])
                }
                try execute("INSERT INTO documents(source_id,fingerprint) VALUES(?,?);", [.text(source.id.uuidString), .text(fingerprint)])
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        try protectFiles()
    }

    func search(query: String, projectID: UUID? = nil, filter: FTSSearchFilter = FTSSearchFilter(),
                limit: Int = 20) throws -> [FTSHit] {
        guard limit > 0 else { return [] }
        let match = Self.matchExpression(query)
        var conditions: [String] = []
        var bindings: [Binding] = []
        if !match.isEmpty { conditions.append("source_fts MATCH ?"); bindings.append(.text(match)) }
        if let projectID { conditions.append("project_id = ?"); bindings.append(.text(projectID.uuidString)) }
        if !filter.recordTypes.isEmpty {
            conditions.append("record_type IN (\(Array(repeating: "?", count: filter.recordTypes.count).joined(separator: ",")))")
            bindings += filter.recordTypes.map(Binding.text)
        }
        if let status = filter.status { conditions.append("status = ?"); bindings.append(.text(status)) }
        if let start = filter.startDate, let end = filter.endDate {
            let field: String
            switch filter.dateBasis {
            case .created: field = "CAST(created_at AS REAL)"
            case .due: field = "CAST(due_at AS REAL)"
            case .taskDueOtherwiseCreated: field = "CASE WHEN record_type='task' THEN CAST(due_at AS REAL) ELSE CAST(created_at AS REAL) END"
            }
            conditions.append("\(field) >= ? AND \(field) < ?")
            bindings += [.number(start.timeIntervalSince1970), .number(end.timeIntervalSince1970)]
        }
        let predicate = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let ranking = match.isEmpty ? "0.0" : "bm25(source_fts, 2.0, 1.0)"
        let sql = """
        SELECT source_id,record_type,project_id,created_at,due_at,status,title,body,source_start,source_end,\(ranking) AS relevance
        FROM source_fts \(predicate)
        ORDER BY relevance ASC, CAST(created_at AS REAL) DESC, CAST(source_start AS INTEGER) ASC;
        """
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var result: [FTSHit] = []
        var included = Set<UUID>()
        var step = sqlite3_step(statement)
        // One best hit per original source keeps citation UUIDs stable and avoids
        // duplicate SwiftUI IDs. Every source chunk was searchable before ranking.
        while step == SQLITE_ROW {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: column(statement, 0)) else { throw FTSIndexError.database("Nevaljan identifikator indeksa.") }
            if included.insert(id).inserted {
                let project = UUID(uuidString: column(statement, 2))
                let due: Date? = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                let source = FTSSource(id: id, recordType: column(statement, 1), projectID: project,
                                       date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), dueDate: due,
                                       status: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : column(statement, 5),
                                       title: column(statement, 6), text: column(statement, 7))
                result.append(FTSHit(source: source, startUTF16: Int(sqlite3_column_int64(statement, 8)),
                                     endUTF16: Int(sqlite3_column_int64(statement, 9)), rank: sqlite3_column_double(statement, 10)))
                if result.count >= min(limit, 50) { return result }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw error() }
        return result
    }

    /// Never interpolate user MATCH syntax. Tokens become quoted prefix terms;
    /// all SQL values, project IDs, dates and statuses are separately bound.
    static func matchExpression(_ query: String) -> String {
        let words = FTSQuery.words(query)
        return words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " OR ")
    }

    static func chunkRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var ranges: [NSRange] = []
        var start = 0
        while start < ns.length {
            let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(chunkLength, ns.length - start)))
            ranges.append(range)
            guard NSMaxRange(range) < ns.length else { break }
            start = max(start + 1, NSMaxRange(range) - chunkOverlap)
        }
        return ranges
    }

    private enum Binding { case text(String), number(Double), integer(Int), null }
    private func prepare(_ sql: String, _ bindings: [Binding] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        do {
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .text(let text):
                    guard text.utf8.count <= Int(Int32.max) else { throw FTSIndexError.database("Tekst je predugačak za indeks.") }
                    status = text.withCString {
                        sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                case .number(let number): status = sqlite3_bind_double(statement, index, number)
                case .integer(let number): status = sqlite3_bind_int64(statement, index, sqlite3_int64(number))
                case .null: status = sqlite3_bind_null(statement, index)
                }
                guard status == SQLITE_OK else { throw error() }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw error() }
    }
    private func executeScript(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func remove(sourceID: String) throws {
        try execute("DELETE FROM source_fts WHERE source_id=?;", [.text(sourceID)])
        try execute("DELETE FROM documents WHERE source_id=?;", [.text(sourceID)])
    }
    private func currentFingerprints() throws -> [String: String] {
        let statement = try prepare("SELECT source_id,fingerprint FROM documents;")
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            result[column(statement, 0)] = column(statement, 1)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw error() }
        return result
    }
    private func column(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }
    private func error() -> FTSIndexError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite")
    }
    private func protectFiles() throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
            }
        }
    }
}

enum FTSQuery {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "hr_HR")).lowercased()
    }

    static func words(_ text: String) -> [String] {
        let stop: Set<String> = ["sto", "sam", "smo", "koji", "koje", "koja", "kako", "jos", "trebam", "treba", "moram",
            "posljednji", "put", "trenutno", "tijekom", "vremena", "prosli", "proslog", "ovaj", "ovog", "sljedeci", "tjedan", "tjedna",
            "danas", "jucer", "projekt", "projekti", "projekta", "zadatak", "zadatke", "zadaci", "problemi", "probleme", "problem",
            "nisam", "nismo", "nije", "rijesio", "rijeseni", "rijesene", "nerijeseni", "nerijesene", "nerijeseno", "otvoreni", "otvorene",
            "izvrseni", "izvrsene", "zavrsio", "izvrsio", "zavrseni", "zavrsene", "rok", "rokovi", "rokom", "roka", "spomenuo", "zabiljezeno",
            "rijesiti", "napraviti", "odraditi", "uciniti", "obaviti", "izvrsiti", "dovrsiti"]
        var seen = Set<String>()
        return normalized(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }
            .map { String($0.prefix(4)) }.filter { seen.insert($0).inserted }.prefix(24).map { $0 }
    }

    static func filter(for query: String, now: Date = Date(), calendar original: Calendar = .current) -> FTSSearchFilter {
        let text = normalized(query)
        var result = FTSSearchFilter()
        let tasks = text.contains("zadat")
        let issues = text.contains("problem")
        let open = ["nisam rijesio", "nisam izvrsio", "nisam zavrsio", "nerijesen", "otvoren", "jos trebam", "sto trebam", "sto moram", "preostal"].contains { text.contains($0) }
        let done = !open && ["rijesen", "izvrsen", "zavrsen"].contains { text.contains($0) }
        if tasks { result.recordTypes = ["task"] }
        else if issues { result.recordTypes = ["issue"] }
        if open || done {
            if result.recordTypes.isEmpty { result.recordTypes = ["task", "issue"] }
            result.status = open ? "open" : "closed"
        }
        var calendar = original
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: now)
        var interval: DateInterval?
        if text.contains("prosli tjedan"), let week = calendar.dateInterval(of: .weekOfYear, for: now),
           let start = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start) {
            interval = DateInterval(start: start, end: week.start)
        } else if text.contains("ovaj tjedan") || text.contains("ovog tjedna") {
            interval = calendar.dateInterval(of: .weekOfYear, for: now)
        } else if text.contains("sljedeci tjedan"), let start = calendar.date(byAdding: .weekOfYear, value: 1, to: now) {
            interval = calendar.dateInterval(of: .weekOfYear, for: start)
        } else if text.contains("jucer"), let start = calendar.date(byAdding: .day, value: -1, to: today) {
            interval = DateInterval(start: start, end: today)
        } else if text.contains("danas"), let end = calendar.date(byAdding: .day, value: 1, to: today) {
            interval = DateInterval(start: today, end: end)
        }
        result.startDate = interval?.start; result.endDate = interval?.end
        let event = ["spomenuo", "zabiljez", "dodao", "razgovara", "dogovorio"].contains { text.contains($0) }
        if text.contains("rok") { result.dateBasis = .due }
        else if !event && (tasks || open || text.contains("trebam") || text.contains("moram")) {
            result.dateBasis = .taskDueOtherwiseCreated
        }
        return result
    }
}
