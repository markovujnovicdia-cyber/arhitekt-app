import Foundation
import SwiftData

enum MemoryKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case note, task, issue, decision, question, agreement, change, deadline, fact, plan, summary
    var id: String { rawValue }
    var label: String {
        switch self {
        case .note: "Bilješka"
        case .task: "Zadatak"
        case .issue: "Problem"
        case .decision: "Odluka"
        case .question: "Otvoreno pitanje"
        case .agreement: "Dogovor"
        case .change: "Promjena"
        case .deadline: "Rok"
        case .fact: "Činjenica"
        case .plan: "Plan"
        case .summary: "Sažetak"
        }
    }
}

enum MemoryCertainty: String, Codable, CaseIterable, Identifiable, Hashable {
    case confirmed, planned, proposed, uncertain
    var id: String { rawValue }
    var label: String {
        switch self {
        case .confirmed: "Potvrđeno"
        case .planned: "Planirano"
        case .proposed: "Prijedlog"
        case .uncertain: "Neizvjesno"
        }
    }
}

/// Audio remains local until an explicit cloud consent. Deleting a project
/// nullifies its link and keeps recordings and their transcript history intact.
@Model final class RecordingSession {
    var id: UUID = UUID()
    var title: String = "Snimka"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var duration: Double = 0
    var stateRaw: String = "stopped"
    var masterRelativePath: String?
    var lastError: String?
    var project: Project?
    @Relationship(deleteRule: .nullify, inverse: \AudioSegment.session)
    var segmentRecords: [AudioSegment]? = []
    @Relationship(deleteRule: .nullify, inverse: \TranscriptVersion.recording)
    var transcriptRecords: [TranscriptVersion]? = []

    var segments: [AudioSegment] { (segmentRecords ?? []).sorted { $0.index < $1.index } }
    var transcripts: [TranscriptVersion] {
        (transcriptRecords ?? []).sorted { $0.revision < $1.revision }
    }
    var latestTranscript: TranscriptVersion? { transcripts.last }

    init(title: String = "Snimka", project: Project? = nil) {
        self.title = title
        self.project = project
    }
}

@Model final class AudioSegment {
    var id: UUID = UUID()
    var index: Int = 0
    var relativePath: String = ""
    var duration: Double = 0
    var createdAt: Date = Date()
    var stateRaw: String = "pending"
    var transcriptText: String = ""
    var lastError: String?
    var session: RecordingSession?

    init(index: Int, relativePath: String, duration: Double = 0, session: RecordingSession? = nil) {
        self.index = index
        self.relativePath = relativePath
        self.duration = duration
        self.session = session
    }
}

/// Treat text as immutable after creation. Corrections create a new revision;
/// provenance always points to the exact version reviewed by the user.
@Model final class TranscriptVersion {
    var id: UUID = UUID()
    var text: String = ""
    var createdAt: Date = Date()
    var provider: String = "ručno"
    var revision: Int = 1
    var supersedesID: UUID?
    var recording: RecordingSession?
    var analysisJSON: String?
    var analysisSummary: String?
    @Relationship(deleteRule: .nullify, inverse: \MemoryEntry.transcript)
    var memoryRecords: [MemoryEntry]? = []

    var memory: [MemoryEntry] { memoryRecords ?? [] }
    init(text: String, recording: RecordingSession? = nil, provider: String = "ručno",
         revision: Int = 1, supersedesID: UUID? = nil) {
        self.text = text
        self.recording = recording
        self.provider = provider
        self.revision = revision
        self.supersedesID = supersedesID
    }
}

/// Append-only facts and suggestions; old entries are kept when a later entry
/// describes a change. No summary replaces source text or earlier decisions.
@Model final class MemoryEntry {
    var id: UUID = UUID()
    var kindRaw: String = MemoryKind.note.rawValue
    var title: String = ""
    var details: String = ""
    var certaintyRaw: String = MemoryCertainty.uncertain.rawValue
    var responsible: String?
    var dueDate: Date?
    var createdAt: Date = Date()
    var sourceTranscriptID: UUID?
    var sourceRecordingID: UUID?
    var startUTF16: Int = 0
    var endUTF16: Int = 0
    var quote: String = ""
    var evidenceKey: String = ""
    var relatedEntryID: UUID?
    var project: Project?
    var transcript: TranscriptVersion?

    var kind: MemoryKind {
        get { MemoryKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }
    var certainty: MemoryCertainty {
        get { MemoryCertainty(rawValue: certaintyRaw) ?? .uncertain }
        set { certaintyRaw = newValue.rawValue }
    }

    init(kind: MemoryKind, title: String, details: String = "", certainty: MemoryCertainty = .uncertain,
         project: Project? = nil, transcript: TranscriptVersion? = nil,
         startUTF16: Int = 0, endUTF16: Int = 0, quote: String = "", evidenceKey: String = "") {
        self.kindRaw = kind.rawValue
        self.title = title
        self.details = details
        self.certaintyRaw = certainty.rawValue
        self.project = project
        self.transcript = transcript
        self.sourceTranscriptID = transcript?.id
        self.sourceRecordingID = transcript?.recording?.id
        self.startUTF16 = startUTF16
        self.endUTF16 = endUTF16
        self.quote = quote
        self.evidenceKey = evidenceKey
    }
}
