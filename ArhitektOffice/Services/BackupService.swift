import Foundation
import SwiftData

struct ImportResult {
    let projectCount: Int
    let itemCount: Int
}

enum BackupError: LocalizedError {
    case tooLarge, unsupportedVersion, invalidData(String), unsavedChanges
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Sigurnosna kopija prelazi dopuštenih 20 MB."
        case .unsupportedVersion: "Ova verzija sigurnosne kopije nije podržana."
        case .invalidData(let reason): "Nevaljana sigurnosna kopija: \(reason)"
        case .unsavedChanges: "Prije uvoza spremite ili otkažite promjene koje uređujete."
        }
    }
}

/// Versioned, local-only backup format. Imports merge by UUID and never remove
/// existing records. A repeated import is idempotent. Matching UUIDs are updated
/// from the backup, so users should export current work before restoring.
@MainActor enum BackupService {
    static let maximumBytes = 20 * 1024 * 1024

    static func export(context: ModelContext) throws -> Data {
        let projects = try context.fetch(FetchDescriptor<Project>()).sorted { $0.id.uuidString < $1.id.uuidString }
        // Detect orphaned records rather than silently excluding user data.
        guard try context.fetch(FetchDescriptor<ProjectTask>()).allSatisfy({ $0.project != nil }),
              try context.fetch(FetchDescriptor<ProjectIssue>()).allSatisfy({ $0.project != nil }),
              try context.fetch(FetchDescriptor<ProjectNote>()).allSatisfy({ $0.project != nil }),
              try context.fetch(FetchDescriptor<PhaseChange>()).allSatisfy({ $0.project != nil }) else {
            throw BackupError.invalidData("postoje zapisi bez povezanog projekta")
        }
        let document = BackupDocument(version: 1, exportedAt: Date(), projects: projects.map(ProjectRecord.init))
        try validate(document)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        return data
    }

    static func importData(_ data: Data, into context: ModelContext) throws -> ImportResult {
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: BackupDocument
        do { document = try decoder.decode(BackupDocument.self, from: data) }
        catch { throw BackupError.invalidData("JSON ne odgovara formatu aplikacije (\(error.localizedDescription))") }
        try validate(document)
        guard !context.hasChanges else { throw BackupError.unsavedChanges }

        let projectIndex = try index(try context.fetch(FetchDescriptor<Project>()), id: { $0.id })
        let taskIndex = try index(try context.fetch(FetchDescriptor<ProjectTask>()), id: { $0.id })
        let issueIndex = try index(try context.fetch(FetchDescriptor<ProjectIssue>()), id: { $0.id })
        let noteIndex = try index(try context.fetch(FetchDescriptor<ProjectNote>()), id: { $0.id })
        let phaseIndex = try index(try context.fetch(FetchDescriptor<PhaseChange>()), id: { $0.id })

        var storedTypes: [UUID: String] = [:]
        func register(_ ids: [UUID], as kind: String) throws {
            for id in ids {
                guard storedTypes.updateValue(kind, forKey: id) == nil else {
                    throw BackupError.invalidData("baza sadrži ponovljene identifikatore različitih zapisa")
                }
            }
        }
        try register(Array(projectIndex.keys), as: "project")
        try register(Array(taskIndex.keys), as: "task")
        try register(Array(issueIndex.keys), as: "issue")
        try register(Array(noteIndex.keys), as: "note")
        try register(Array(phaseIndex.keys), as: "phase")
        func checkType(_ id: UUID, kind: String) throws {
            if let stored = storedTypes[id], stored != kind {
                throw BackupError.invalidData("identifikator se već koristi za drugu vrstu zapisa")
            }
        }

        // Validate all relationship collisions before making the first mutation.
        for project in document.projects {
            try checkType(project.id, kind: "project")
            for record in project.tasks {
                try checkType(record.id, kind: "task")
                try checkOwner(taskIndex[record.id]?.project, expected: project.id)
            }
            for record in project.issues {
                try checkType(record.id, kind: "issue")
                try checkOwner(issueIndex[record.id]?.project, expected: project.id)
            }
            for record in project.notes {
                try checkType(record.id, kind: "note")
                try checkOwner(noteIndex[record.id]?.project, expected: project.id)
            }
            for record in project.phaseHistory {
                try checkType(record.id, kind: "phase")
                try checkOwner(phaseIndex[record.id]?.project, expected: project.id)
            }
        }
        do {
            for record in document.projects {
                let project = projectIndex[record.id] ?? Project(name: record.name, recordInitialPhase: false)
                if projectIndex[record.id] == nil { context.insert(project) }
                project.id = record.id
                project.name = record.name
                project.number = record.number
                project.investor = record.investor
                project.location = record.location
                project.buildingType = record.buildingType
                project.phase = record.phase
                project.startedAt = record.startedAt
                project.lastActivity = record.lastActivity
                project.isArchived = record.isArchived
                for entry in record.tasks {
                    let task = taskIndex[entry.id] ?? ProjectTask(title: entry.title)
                    if taskIndex[entry.id] == nil { context.insert(task) }
                    task.id = entry.id
                    task.title = entry.title
                    task.details = entry.details
                    task.createdAt = entry.createdAt
                    task.dueDate = entry.dueDate
                    task.priority = entry.priority
                    task.status = entry.status
                    task.project = project
                }
                for entry in record.issues {
                    let issue = issueIndex[entry.id] ?? ProjectIssue(title: entry.title)
                    if issueIndex[entry.id] == nil { context.insert(issue) }
                    issue.id = entry.id
                    issue.title = entry.title
                    issue.details = entry.details
                    issue.resolution = entry.resolution
                    issue.status = entry.status
                    issue.createdAt = entry.createdAt
                    issue.project = project
                }
                for entry in record.notes {
                    let note = noteIndex[entry.id] ?? ProjectNote(text: entry.text)
                    if noteIndex[entry.id] == nil { context.insert(note) }
                    note.id = entry.id
                    note.text = entry.text
                    note.sourceTranscript = entry.sourceTranscript
                    note.createdAt = entry.createdAt
                    note.modifiedAt = entry.modifiedAt
                    note.project = project
                }
                for entry in record.phaseHistory {
                    let event = phaseIndex[entry.id] ?? PhaseChange(phase: entry.phase)
                    if phaseIndex[entry.id] == nil { context.insert(event) }
                    event.id = entry.id
                    event.phase = entry.phase
                    event.changedAt = entry.changedAt
                    event.project = project
                }
            }
            // One save makes the graph atomic in the local persistent store.
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return ImportResult(projectCount: document.projects.count, itemCount: document.projects.reduce(0) {
            $0 + $1.tasks.count + $1.issues.count + $1.notes.count
        })
    }

    private static func checkOwner(_ owner: Project?, expected: UUID) throws {
        if let owner, owner.id != expected {
            throw BackupError.invalidData("isti identifikator zapisa pripada drugom projektu")
        }
    }

    private static func index<T>(_ values: [T], id: (T) -> UUID) throws -> [UUID: T] {
        var result: [UUID: T] = [:]
        for value in values {
            guard result.updateValue(value, forKey: id(value)) == nil else {
                throw BackupError.invalidData("baza sadrži ponovljene identifikatore")
            }
        }
        return result
    }

    private static func validate(_ document: BackupDocument) throws {
        guard document.version == 1 else { throw BackupError.unsupportedVersion }
        guard document.projects.count <= 10_000 else { throw BackupError.invalidData("previše projekata") }
        var ids = Set<UUID>()
        func unique(_ id: UUID) throws {
            guard ids.insert(id).inserted else { throw BackupError.invalidData("ponovljen identifikator") }
        }
        func text(_ value: String, required: Bool = false) throws {
            guard value.utf8.count <= 1_000_000,
                  !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BackupError.invalidData("prazan obvezni tekst ili predugačak tekst")
            }
        }
        func date(_ value: Date) throws {
            guard value.timeIntervalSince1970.isFinite else { throw BackupError.invalidData("nevaljan datum") }
        }
        try date(document.exportedAt)
        for project in document.projects {
            try unique(project.id)
            try text(project.name, required: true)
            for value in [project.number, project.investor, project.location, project.buildingType] { try text(value) }
            try date(project.startedAt)
            try date(project.lastActivity)
            for task in project.tasks {
                try unique(task.id); try text(task.title, required: true); try text(task.details)
                try date(task.createdAt)
                if let due = task.dueDate { try date(due) }
            }
            for issue in project.issues {
                try unique(issue.id); try text(issue.title, required: true)
                try text(issue.details); try text(issue.resolution); try date(issue.createdAt)
            }
            for note in project.notes {
                try unique(note.id); try text(note.text, required: true)
                if let source = note.sourceTranscript { try text(source) }
                try date(note.createdAt); try date(note.modifiedAt)
            }
            for phase in project.phaseHistory { try unique(phase.id); try date(phase.changedAt) }
        }
    }
}

private struct BackupDocument: Codable {
    var version: Int
    var exportedAt: Date
    var projects: [ProjectRecord]
}

private struct ProjectRecord: Codable {
    var id: UUID
    var name: String
    var number: String
    var investor: String
    var location: String
    var buildingType: String
    var phase: ProjectPhase
    var startedAt: Date
    var lastActivity: Date
    var isArchived: Bool
    var tasks: [TaskRecord]
    var issues: [IssueRecord]
    var notes: [NoteRecord]
    var phaseHistory: [PhaseRecord]

    init(_ project: Project) {
        id = project.id; name = project.name; number = project.number
        investor = project.investor; location = project.location; buildingType = project.buildingType
        phase = project.phase; startedAt = project.startedAt; lastActivity = project.lastActivity
        isArchived = project.isArchived
        tasks = project.tasks.sorted { $0.id.uuidString < $1.id.uuidString }.map(TaskRecord.init)
        issues = project.issues.sorted { $0.id.uuidString < $1.id.uuidString }.map(IssueRecord.init)
        notes = project.notes.sorted { $0.id.uuidString < $1.id.uuidString }.map(NoteRecord.init)
        phaseHistory = project.phaseHistory.sorted { $0.changedAt < $1.changedAt }.map(PhaseRecord.init)
    }
}

private struct TaskRecord: Codable {
    var id: UUID; var title: String; var details: String; var createdAt: Date
    var dueDate: Date?; var priority: TaskPriority; var status: TaskStatus
    init(_ task: ProjectTask) {
        id = task.id; title = task.title; details = task.details; createdAt = task.createdAt
        dueDate = task.dueDate; priority = task.priority; status = task.status
    }
}

private struct IssueRecord: Codable {
    var id: UUID; var title: String; var details: String; var resolution: String
    var createdAt: Date; var status: IssueStatus
    init(_ issue: ProjectIssue) {
        id = issue.id; title = issue.title; details = issue.details; resolution = issue.resolution
        createdAt = issue.createdAt; status = issue.status
    }
}

private struct NoteRecord: Codable {
    var id: UUID; var text: String; var sourceTranscript: String?
    var createdAt: Date; var modifiedAt: Date
    init(_ note: ProjectNote) {
        id = note.id; text = note.text; sourceTranscript = note.sourceTranscript
        createdAt = note.createdAt; modifiedAt = note.modifiedAt
    }
}

private struct PhaseRecord: Codable {
    var id: UUID; var phase: ProjectPhase; var changedAt: Date
    init(_ event: PhaseChange) { id = event.id; phase = event.phase; changedAt = event.changedAt }
}
