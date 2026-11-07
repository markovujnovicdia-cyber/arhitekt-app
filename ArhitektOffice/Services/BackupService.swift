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

    static func validate(data: Data) throws {
        _ = try decodedDocument(data)
    }

    static func audioRelativePaths(in data: Data) throws -> [String] {
        let document = try decodedDocument(data)
        return Array(Set((document.recordings ?? []).compactMap(\.masterRelativePath) +
                         (document.segments ?? []).map(\.relativePath))).sorted()
    }

    private static func decodedDocument(_ data: Data) throws -> BackupDocument {
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: BackupDocument
        do { document = try decoder.decode(BackupDocument.self, from: data) }
        catch { throw BackupError.invalidData("JSON ne odgovara formatu aplikacije (\(error.localizedDescription))") }
        try validate(document)
        return document
    }

    static func export(context: ModelContext) throws -> Data {
        let projects = try context.fetch(FetchDescriptor<Project>()).sorted { $0.id.uuidString < $1.id.uuidString }
        // Detect orphaned records rather than silently excluding user data.
        guard try context.fetch(FetchDescriptor<ProjectTask>()).allSatisfy({ $0.project != nil }),
              try context.fetch(FetchDescriptor<ProjectIssue>()).allSatisfy({ $0.project != nil }),
              try context.fetch(FetchDescriptor<ProjectNote>()).allSatisfy({ $0.project != nil }),
              try context.fetch(FetchDescriptor<PhaseChange>()).allSatisfy({ $0.project != nil }) else {
            throw BackupError.invalidData("postoje zapisi bez povezanog projekta")
        }
        let document = BackupDocument(version: 2, exportedAt: Date(), projects: projects.map(ProjectRecord.init),
                                      recordings: try context.fetch(FetchDescriptor<RecordingSession>()).map(RecordingRecord.init),
                                      segments: try context.fetch(FetchDescriptor<AudioSegment>()).map(AudioRecord.init),
                                      transcripts: try context.fetch(FetchDescriptor<TranscriptVersion>()).map(TranscriptRecord.init),
                                      memory: try context.fetch(FetchDescriptor<MemoryEntry>()).map(MemoryRecord.init))
        try validate(document)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        return data
    }

    static func importData(_ data: Data, into context: ModelContext) throws -> ImportResult {
        let document = try decodedDocument(data)
        guard !context.hasChanges else { throw BackupError.unsavedChanges }

        let projectIndex = try index(try context.fetch(FetchDescriptor<Project>()), id: { $0.id })
        let taskIndex = try index(try context.fetch(FetchDescriptor<ProjectTask>()), id: { $0.id })
        let issueIndex = try index(try context.fetch(FetchDescriptor<ProjectIssue>()), id: { $0.id })
        let noteIndex = try index(try context.fetch(FetchDescriptor<ProjectNote>()), id: { $0.id })
        let phaseIndex = try index(try context.fetch(FetchDescriptor<PhaseChange>()), id: { $0.id })
        try MetadataBackup.preflight(document, context: context)

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
                    if let responsible = entry.responsible { task.responsible = responsible }
                    if let memoryID = entry.sourceMemoryID { task.sourceMemoryID = memoryID }
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
                    if let memoryID = entry.sourceMemoryID { issue.sourceMemoryID = memoryID }
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
                    if let memoryID = entry.sourceMemoryID { note.sourceMemoryID = memoryID }
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
            try MetadataBackup.restore(document, context: context)
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
        guard document.version == 1 || document.version == 2 else { throw BackupError.unsupportedVersion }
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
        try MetadataBackup.validate(document, usedIDs: ids)
    }
}

private struct BackupDocument: Codable {
    var version: Int
    var exportedAt: Date
    var projects: [ProjectRecord]
    var recordings: [RecordingRecord]?
    var segments: [AudioRecord]?
    var transcripts: [TranscriptRecord]?
    var memory: [MemoryRecord]?
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
    var responsible: String?; var sourceMemoryID: UUID?
    init(_ task: ProjectTask) {
        id = task.id; title = task.title; details = task.details; createdAt = task.createdAt
        dueDate = task.dueDate; priority = task.priority; status = task.status
        responsible = task.responsible; sourceMemoryID = task.sourceMemoryID
    }
}

private struct IssueRecord: Codable {
    var id: UUID; var title: String; var details: String; var resolution: String
    var createdAt: Date; var status: IssueStatus
    var sourceMemoryID: UUID?
    init(_ issue: ProjectIssue) {
        id = issue.id; title = issue.title; details = issue.details; resolution = issue.resolution
        createdAt = issue.createdAt; status = issue.status
        sourceMemoryID = issue.sourceMemoryID
    }
}

private struct NoteRecord: Codable {
    var id: UUID; var text: String; var sourceTranscript: String?
    var createdAt: Date; var modifiedAt: Date
    var sourceMemoryID: UUID?
    init(_ note: ProjectNote) {
        id = note.id; text = note.text; sourceTranscript = note.sourceTranscript
        createdAt = note.createdAt; modifiedAt = note.modifiedAt
        sourceMemoryID = note.sourceMemoryID
    }
}

private struct PhaseRecord: Codable {
    var id: UUID; var phase: ProjectPhase; var changedAt: Date
    init(_ event: PhaseChange) { id = event.id; phase = event.phase; changedAt = event.changedAt }
}

private struct RecordingRecord: Codable {
    var id: UUID; var title: String; var createdAt: Date; var updatedAt: Date
    var duration: Double; var stateRaw: String; var masterRelativePath: String?; var lastError: String?; var projectID: UUID?
    init(_ value: RecordingSession) {
        id = value.id; title = value.title; createdAt = value.createdAt; updatedAt = value.updatedAt
        duration = value.duration; stateRaw = value.stateRaw; masterRelativePath = value.masterRelativePath
        lastError = value.lastError; projectID = value.project?.id
    }
}

private struct AudioRecord: Codable {
    var id: UUID; var index: Int; var relativePath: String; var duration: Double; var createdAt: Date
    var stateRaw: String; var transcriptText: String; var lastError: String?; var sessionID: UUID?
    init(_ value: AudioSegment) {
        id = value.id; index = value.index; relativePath = value.relativePath; duration = value.duration
        createdAt = value.createdAt; stateRaw = value.stateRaw; transcriptText = value.transcriptText
        lastError = value.lastError; sessionID = value.session?.id
    }
}

private struct TranscriptRecord: Codable {
    var id: UUID; var text: String; var createdAt: Date; var provider: String; var revision: Int
    var supersedesID: UUID?; var recordingID: UUID?; var analysisJSON: String?; var analysisSummary: String?
    init(_ value: TranscriptVersion) {
        id = value.id; text = value.text; createdAt = value.createdAt; provider = value.provider
        revision = value.revision; supersedesID = value.supersedesID; recordingID = value.recording?.id
        analysisJSON = value.analysisJSON; analysisSummary = value.analysisSummary
    }
}

private struct MemoryRecord: Codable {
    var id: UUID; var kind: MemoryKind; var title: String; var details: String; var certainty: MemoryCertainty
    var responsible: String?; var dueDate: Date?; var createdAt: Date; var projectID: UUID?
    var transcriptID: UUID?; var sourceTranscriptID: UUID?; var sourceRecordingID: UUID?
    var startUTF16: Int; var endUTF16: Int; var quote: String; var evidenceKey: String; var relatedEntryID: UUID?
    init(_ value: MemoryEntry) {
        id = value.id; kind = value.kind; title = value.title; details = value.details; certainty = value.certainty
        responsible = value.responsible; dueDate = value.dueDate; createdAt = value.createdAt
        projectID = value.project?.id; transcriptID = value.transcript?.id; sourceTranscriptID = value.sourceTranscriptID
        sourceRecordingID = value.sourceRecordingID; startUTF16 = value.startUTF16; endUTF16 = value.endUTF16
        quote = value.quote; evidenceKey = value.evidenceKey; relatedEntryID = value.relatedEntryID
    }
}

/// Validation and restoration are separate so malformed metadata cannot partly
/// import older project records. This helper never saves on its own.
@MainActor private enum MetadataBackup {
    static func validate(_ document: BackupDocument, usedIDs: Set<UUID>) throws {
        if document.version == 2 {
            guard document.recordings != nil, document.segments != nil,
                  document.transcripts != nil, document.memory != nil else { throw invalid("nedostaje memorija verzije 2") }
        }
        var ids = usedIDs
        func unique(_ id: UUID) throws {
            guard ids.insert(id).inserted else { throw invalid("ponovljen identifikator memorije") }
        }
        func text(_ value: String?, required: Bool = false, max: Int = 5_000_000) throws {
            guard let value else { if required { throw invalid("nedostaje obvezni tekst") }; return }
            guard value.utf8.count <= max, !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("prazan ili predugačak tekst memorije")
            }
        }
        func date(_ value: Date?) throws {
            if let value, !value.timeIntervalSince1970.isFinite { throw invalid("nevaljan datum memorije") }
        }
        let projects = Set(document.projects.map(\.id))
        let recordings = document.recordings ?? []
        let segments = document.segments ?? []
        let transcripts = document.transcripts ?? []
        let memory = document.memory ?? []
        let recordingIDs = Set(recordings.map(\.id))
        let transcriptIDs = Set(transcripts.map(\.id))
        let memoryIDs = Set(memory.map(\.id))
        for recording in recordings {
            try unique(recording.id); try text(recording.title, required: true); try text(recording.lastError)
            try text(recording.stateRaw, required: true); try date(recording.createdAt); try date(recording.updatedAt)
            guard recording.duration.isFinite, recording.duration >= 0 else { throw invalid("nevaljano trajanje snimke") }
            if let path = recording.masterRelativePath { try safePath(path) }
            if let project = recording.projectID, !projects.contains(project) { throw invalid("snimka ima nepoznat projekt") }
        }
        var segmentOrder = Set<String>()
        for segment in segments {
            try unique(segment.id); try safePath(segment.relativePath); try date(segment.createdAt)
            try text(segment.transcriptText); try text(segment.lastError); try text(segment.stateRaw, required: true)
            guard segment.index >= 0, segment.duration.isFinite, segment.duration >= 0 else { throw invalid("nevaljan dio snimke") }
            if let session = segment.sessionID {
                guard recordingIDs.contains(session), segmentOrder.insert("\(session)-\(segment.index)").inserted else {
                    throw invalid("nepoznata snimka ili ponovljen redni broj dijela")
                }
            }
        }
        var revisions = Set<String>()
        for transcript in transcripts {
            try unique(transcript.id); try text(transcript.text, required: true); try text(transcript.provider)
            try text(transcript.analysisJSON); try text(transcript.analysisSummary); try date(transcript.createdAt)
            guard transcript.revision > 0 else { throw invalid("nevaljana revizija transkripta") }
            if let recording = transcript.recordingID {
                guard recordingIDs.contains(recording), revisions.insert("\(recording)-\(transcript.revision)").inserted else {
                    throw invalid("nepoznata snimka ili ponovljena revizija transkripta")
                }
            }
            if let previousID = transcript.supersedesID {
                guard let previous = transcripts.first(where: { $0.id == previousID }),
                      previous.recordingID == transcript.recordingID, previous.revision < transcript.revision else {
                    throw invalid("nevaljana povijest revizija")
                }
            }
        }
        var evidenceKeys = Set<String>()
        for entry in memory {
            try unique(entry.id); try text(entry.title, required: true); try text(entry.details)
            try text(entry.responsible); try text(entry.quote, required: true); try date(entry.createdAt); try date(entry.dueDate)
            guard !entry.evidenceKey.isEmpty, evidenceKeys.insert(entry.evidenceKey).inserted else { throw invalid("ponovljen izvor memorije") }
            if let project = entry.projectID, !projects.contains(project) { throw invalid("memorija ima nepoznat projekt") }
            if let recording = entry.sourceRecordingID, !recordingIDs.contains(recording) { throw invalid("memorija ima nepoznatu snimku") }
            if let related = entry.relatedEntryID {
                guard related != entry.id, let previous = memory.first(where: { $0.id == related }),
                      previous.projectID == entry.projectID else { throw invalid("nevaljana poveznica memorije") }
            }
            guard let sourceID = entry.transcriptID ?? entry.sourceTranscriptID,
                  transcriptIDs.contains(sourceID),
                  let transcript = transcripts.first(where: { $0.id == sourceID }),
                  entry.sourceTranscriptID == nil || entry.sourceTranscriptID == sourceID,
                  entry.sourceRecordingID == nil || entry.sourceRecordingID == transcript.recordingID,
                  entry.startUTF16 >= 0, entry.endUTF16 > entry.startUTF16,
                  entry.endUTF16 <= transcript.text.utf16.count,
                  let range = Range(NSRange(location: entry.startUTF16, length: entry.endUTF16 - entry.startUTF16), in: transcript.text),
                  transcript.text[range].utf16.elementsEqual(entry.quote.utf16) else { throw invalid("memorija nema valjan izvor") }
        }
        for project in document.projects {
            for reference in project.tasks.map(\.sourceMemoryID) + project.issues.map(\.sourceMemoryID) + project.notes.map(\.sourceMemoryID) {
                if let reference, !memoryIDs.contains(reference), document.version == 2 { throw invalid("nepoznat izvor starog zapisa") }
            }
        }
    }

    static func preflight(_ document: BackupDocument, context: ModelContext) throws {
        let recordings = try checkedIndex(context.fetch(FetchDescriptor<RecordingSession>()), id: { $0.id })
        let segments = try checkedIndex(context.fetch(FetchDescriptor<AudioSegment>()), id: { $0.id })
        let transcripts = try checkedIndex(context.fetch(FetchDescriptor<TranscriptVersion>()), id: { $0.id })
        let memory = try checkedIndex(context.fetch(FetchDescriptor<MemoryEntry>()), id: { $0.id })
        var existingTypes: [UUID: String] = [:]
        func register(_ ids: [UUID], _ kind: String) throws {
            for id in ids {
                guard existingTypes.updateValue(kind, forKey: id) == nil else { throw invalid("baza sadrži ponovljene identifikatore") }
            }
        }
        try register(try context.fetch(FetchDescriptor<Project>()).map(\.id), "project")
        try register(try context.fetch(FetchDescriptor<ProjectTask>()).map(\.id), "task")
        try register(try context.fetch(FetchDescriptor<ProjectIssue>()).map(\.id), "issue")
        try register(try context.fetch(FetchDescriptor<ProjectNote>()).map(\.id), "note")
        try register(try context.fetch(FetchDescriptor<PhaseChange>()).map(\.id), "phase")
        try register(Array(recordings.keys), "recording"); try register(Array(segments.keys), "segment")
        try register(Array(transcripts.keys), "transcript"); try register(Array(memory.keys), "memory")
        func checkType(_ id: UUID, _ kind: String) throws {
            if let existing = existingTypes[id], existing != kind { throw invalid("identifikator pripada drugoj vrsti zapisa") }
        }
        for project in document.projects {
            try checkType(project.id, "project")
            for value in project.tasks { try checkType(value.id, "task") }
            for value in project.issues { try checkType(value.id, "issue") }
            for value in project.notes { try checkType(value.id, "note") }
            for value in project.phaseHistory { try checkType(value.id, "phase") }
        }
        for record in document.recordings ?? [] {
            try checkType(record.id, "recording")
            if let existing = recordings[record.id], let path = existing.masterRelativePath,
               let incoming = record.masterRelativePath, path != incoming { throw invalid("isti identifikator ima drugu izvornu snimku") }
        }
        for record in document.segments ?? [] {
            try checkType(record.id, "segment")
            if let existing = segments[record.id], existing.relativePath != record.relativePath ||
                existing.index != record.index || existing.session?.id != record.sessionID {
                throw invalid("postojeći dio snimke ne smije se zamijeniti")
            }
        }
        for record in document.transcripts ?? [] {
            try checkType(record.id, "transcript")
            if let existing = transcripts[record.id], existing.text != record.text || existing.revision != record.revision ||
                existing.recording?.id != record.recordingID || existing.supersedesID != record.supersedesID {
                throw invalid("postojeća revizija transkripta ne smije se prepisati")
            }
        }
        for record in document.memory ?? [] {
            try checkType(record.id, "memory")
            if let existing = memory[record.id] {
                guard existing.kind == record.kind, existing.certainty == record.certainty,
                      existing.title == record.title, existing.details == record.details,
                      existing.quote == record.quote, existing.evidenceKey == record.evidenceKey,
                      existing.startUTF16 == record.startUTF16, existing.endUTF16 == record.endUTF16,
                      existing.sourceTranscriptID == record.sourceTranscriptID,
                      existing.sourceRecordingID == record.sourceRecordingID,
                      existing.project == nil || existing.project?.id == record.projectID,
                      existing.transcript == nil || existing.transcript?.id == record.transcriptID,
                      existing.responsible == record.responsible,
                      existing.dueDate?.timeIntervalSince1970.rounded(.down) == record.dueDate?.timeIntervalSince1970.rounded(.down),
                      existing.relatedEntryID == record.relatedEntryID else { throw invalid("postojeća memorija ne smije se prepisati") }
            }
            if memory.values.contains(where: { $0.evidenceKey == record.evidenceKey && $0.id != record.id }) {
                throw invalid("isti izvor memorije ima drugi identifikator")
            }
        }
    }

    static func restore(_ document: BackupDocument, context: ModelContext) throws {
        let projects = try checkedIndex(context.fetch(FetchDescriptor<Project>()), id: { $0.id })
        var recordings = try checkedIndex(context.fetch(FetchDescriptor<RecordingSession>()), id: { $0.id })
        var segments = try checkedIndex(context.fetch(FetchDescriptor<AudioSegment>()), id: { $0.id })
        var transcripts = try checkedIndex(context.fetch(FetchDescriptor<TranscriptVersion>()), id: { $0.id })
        let memory = try checkedIndex(context.fetch(FetchDescriptor<MemoryEntry>()), id: { $0.id })
        for record in document.recordings ?? [] {
            let value = recordings[record.id] ?? RecordingSession(title: record.title)
            if recordings[record.id] == nil { context.insert(value) }
            value.id = record.id; value.title = record.title; value.createdAt = record.createdAt
            value.updatedAt = record.updatedAt; value.duration = max(value.duration, record.duration)
            value.stateRaw = ["recording", "paused", "preparing"].contains(record.stateRaw) ? "recovered" : record.stateRaw
            if let path = record.masterRelativePath { value.masterRelativePath = path }
            value.lastError = record.lastError; value.project = record.projectID.flatMap { projects[$0] }
            recordings[record.id] = value
        }
        for record in document.segments ?? [] {
            let value = segments[record.id] ?? AudioSegment(index: record.index, relativePath: record.relativePath)
            if segments[record.id] == nil { context.insert(value) }
            value.id = record.id; value.index = record.index; value.relativePath = record.relativePath
            value.duration = record.duration; value.createdAt = record.createdAt; value.stateRaw = record.stateRaw
            value.transcriptText = record.transcriptText; value.lastError = record.lastError
            value.session = record.sessionID.flatMap { recordings[$0] }; segments[record.id] = value
        }
        for record in document.transcripts ?? [] {
            if let value = transcripts[record.id] {
                if value.analysisJSON == nil { value.analysisJSON = record.analysisJSON }
                if value.analysisSummary == nil { value.analysisSummary = record.analysisSummary }
                continue
            }
            let value = TranscriptVersion(text: record.text, recording: record.recordingID.flatMap { recordings[$0] },
                                          provider: record.provider, revision: record.revision, supersedesID: record.supersedesID)
            value.id = record.id; value.createdAt = record.createdAt
            value.analysisJSON = record.analysisJSON; value.analysisSummary = record.analysisSummary
            context.insert(value); transcripts[record.id] = value
        }
        for record in document.memory ?? [] {
            if let existing = memory[record.id] {
                // Restoring an intentionally removed project may restore its
                // ownership link; the historical content itself remains intact.
                if existing.project == nil { existing.project = record.projectID.flatMap { projects[$0] } }
                if existing.transcript == nil { existing.transcript = record.transcriptID.flatMap { transcripts[$0] } }
                continue
            }
            let value = MemoryEntry(kind: record.kind, title: record.title, details: record.details, certainty: record.certainty,
                                    project: record.projectID.flatMap { projects[$0] }, transcript: record.transcriptID.flatMap { transcripts[$0] },
                                    startUTF16: record.startUTF16, endUTF16: record.endUTF16, quote: record.quote, evidenceKey: record.evidenceKey)
            value.id = record.id; value.createdAt = record.createdAt; value.responsible = record.responsible; value.dueDate = record.dueDate
            value.sourceTranscriptID = record.sourceTranscriptID; value.sourceRecordingID = record.sourceRecordingID
            value.relatedEntryID = record.relatedEntryID; context.insert(value)
        }
    }

    private static func safePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw invalid("nesigurna putanja snimke") }
    }

    private static func checkedIndex<T>(_ values: [T], id: (T) -> UUID) throws -> [UUID: T] {
        var result: [UUID: T] = [:]
        for value in values {
            guard result.updateValue(value, forKey: id(value)) == nil else { throw invalid("ponovljen identifikator u bazi") }
        }
        return result
    }
    private static func invalid(_ text: String) -> BackupError { .invalidData(text) }
}
