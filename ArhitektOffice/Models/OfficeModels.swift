import Foundation
import SwiftData

enum ProjectPhase: String, Codable, CaseIterable, Identifiable, Hashable {
    case conditions = "Uvjeti"
    case concept = "Idejni projekt"
    case main = "Glavni projekt"
    case completed = "Završen"
    var id: String { rawValue }
}

enum TaskPriority: String, Codable, CaseIterable, Identifiable, Hashable {
    case low = "Nizak"
    case normal = "Srednji"
    case high = "Visok"
    var id: String { rawValue }
    var rank: Int { switch self { case .low: 0; case .normal: 1; case .high: 2 } }
}

enum TaskStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case open = "Otvoren"
    case completed = "Izvršen"
    var id: String { rawValue }
}

enum IssueStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case open = "Otvoren"
    case resolved = "Riješen"
    var id: String { rawValue }
}

// Stable UUIDs, optional inverse relationships, defaults and no unique constraints
// keep the schema suitable for a future CloudKit-backed ModelConfiguration.
// Cloud syncing is deliberately disabled until users explicitly opt in.
@Model final class Project {
    var id: UUID = UUID()
    var name: String = ""
    var number: String = ""
    var investor: String = ""
    var location: String = ""
    var buildingType: String = ""
    var phaseRaw: String = ProjectPhase.conditions.rawValue
    var startedAt: Date = Date()
    var lastActivity: Date = Date()
    var isArchived: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \ProjectTask.project)
    var taskRecords: [ProjectTask]? = []
    @Relationship(deleteRule: .cascade, inverse: \ProjectIssue.project)
    var issueRecords: [ProjectIssue]? = []
    @Relationship(deleteRule: .cascade, inverse: \ProjectNote.project)
    var noteRecords: [ProjectNote]? = []
    @Relationship(deleteRule: .cascade, inverse: \PhaseChange.project)
    var phaseRecords: [PhaseChange]? = []
    @Relationship(deleteRule: .nullify, inverse: \RecordingSession.project)
    var recordingRecords: [RecordingSession]? = []
    @Relationship(deleteRule: .nullify, inverse: \MemoryEntry.project)
    var memoryRecords: [MemoryEntry]? = []

    var phase: ProjectPhase {
        get { ProjectPhase(rawValue: phaseRaw) ?? .conditions }
        set { phaseRaw = newValue.rawValue }
    }
    var tasks: [ProjectTask] { taskRecords ?? [] }
    var issues: [ProjectIssue] { issueRecords ?? [] }
    var notes: [ProjectNote] { noteRecords ?? [] }
    var phaseHistory: [PhaseChange] { phaseRecords ?? [] }
    var recordings: [RecordingSession] { recordingRecords ?? [] }
    var memory: [MemoryEntry] { memoryRecords ?? [] }
    var openTaskCount: Int { tasks.filter { $0.status == .open }.count }
    var openIssueCount: Int { issues.filter { $0.status == .open }.count }

    init(name: String, number: String = "", investor: String = "", location: String = "",
         buildingType: String = "", phase: ProjectPhase = .conditions, startedAt: Date = Date(),
         recordInitialPhase: Bool = true) {
        self.name = name
        self.number = number
        self.investor = investor
        self.location = location
        self.buildingType = buildingType
        self.phaseRaw = phase.rawValue
        self.startedAt = startedAt
        self.lastActivity = Date()
        if recordInitialPhase {
            let initial = PhaseChange(phase: phase, changedAt: startedAt)
            self.phaseRecords = [initial]
            initial.project = self
        }
    }

    func touch(at date: Date = Date()) { lastActivity = date }

    func changePhase(to newPhase: ProjectPhase, at date: Date = Date()) {
        guard phase != newPhase else { return }
        phase = newPhase
        let event = PhaseChange(phase: newPhase, changedAt: date)
        event.project = self
        if !(phaseRecords ?? []).contains(where: { $0.id == event.id }) {
            if phaseRecords == nil { phaseRecords = [] }
            phaseRecords?.append(event)
        }
        touch(at: date)
    }
}

@Model final class ProjectTask {
    var id: UUID = UUID()
    var title: String = ""
    var details: String = ""
    var dueDate: Date?
    var priorityRaw: String = TaskPriority.normal.rawValue
    var statusRaw: String = TaskStatus.open.rawValue
    var createdAt: Date = Date()
    var responsible: String?
    var sourceMemoryID: UUID?
    var project: Project?

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }
    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }
    init(title: String, details: String = "", dueDate: Date? = nil,
         priority: TaskPriority = .normal, project: Project? = nil) {
        self.title = title
        self.details = details
        self.dueDate = dueDate
        self.priorityRaw = priority.rawValue
        self.project = project
    }
}

@Model final class ProjectIssue {
    var id: UUID = UUID()
    var title: String = ""
    var details: String = ""
    var resolution: String = ""
    var statusRaw: String = IssueStatus.open.rawValue
    var createdAt: Date = Date()
    var sourceMemoryID: UUID?
    var project: Project?

    var status: IssueStatus {
        get { IssueStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }
    init(title: String, details: String = "", project: Project? = nil) {
        self.title = title
        self.details = details
        self.project = project
    }
}

@Model final class ProjectNote {
    var id: UUID = UUID()
    var text: String = ""
    var sourceTranscript: String?
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var sourceMemoryID: UUID?
    var project: Project?

    init(text: String, sourceTranscript: String? = nil, project: Project? = nil) {
        self.text = text
        self.sourceTranscript = sourceTranscript
        self.project = project
    }
}

@Model final class PhaseChange {
    var id: UUID = UUID()
    var phaseRaw: String = ProjectPhase.conditions.rawValue
    var changedAt: Date = Date()
    var project: Project?
    var phase: ProjectPhase {
        get { ProjectPhase(rawValue: phaseRaw) ?? .conditions }
        set { phaseRaw = newValue.rawValue }
    }
    init(phase: ProjectPhase, changedAt: Date = Date()) {
        self.phaseRaw = phase.rawValue
        self.changedAt = changedAt
    }
}
