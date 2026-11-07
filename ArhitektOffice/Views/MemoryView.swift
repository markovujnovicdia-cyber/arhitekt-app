import SwiftUI
import SwiftData

/// A single chronological index. Original records are retained, never replaced by summaries.
enum MemoryTimelineItem: Identifiable {
    case recording(RecordingSession), entry(MemoryEntry), note(ProjectNote)
    case task(ProjectTask), issue(ProjectIssue), phase(PhaseChange)

    var id: String {
        switch self {
        case .recording(let value): return "recording:\(value.id)"
        case .entry(let value): return "memory:\(value.id)"
        case .note(let value): return "note:\(value.id)"
        case .task(let value): return "task:\(value.id)"
        case .issue(let value): return "issue:\(value.id)"
        case .phase(let value): return "phase:\(value.id)"
        }
    }
    var date: Date {
        switch self {
        case .recording(let value): return value.createdAt
        case .entry(let value): return value.createdAt
        case .note(let value): return value.createdAt
        case .task(let value): return value.createdAt
        case .issue(let value): return value.createdAt
        case .phase(let value): return value.changedAt
        }
    }
    var project: Project? {
        switch self {
        case .recording(let value): return value.project
        case .entry(let value): return value.project
        case .note(let value): return value.project
        case .task(let value): return value.project
        case .issue(let value): return value.project
        case .phase(let value): return value.project
        }
    }
    var title: String {
        switch self {
        case .recording(let value): return value.title
        case .entry(let value): return value.title
        case .note(let value): return String(value.text.prefix(100))
        case .task(let value): return value.title
        case .issue(let value): return value.title
        case .phase(let value): return "Faza: " + value.phase.rawValue
        }
    }
    var detail: String {
        switch self {
        case .recording(let value): return value.transcripts.map(\.text).joined(separator: "\n")
        case .entry(let value): return value.details + "\n" + value.quote
        case .note(let value): return value.text + "\n" + (value.sourceTranscript ?? "")
        case .task(let value): return value.details + "\n" + value.status.rawValue
        case .issue(let value): return value.details + "\n" + value.resolution
        case .phase: return "Promjena faze projekta"
        }
    }
    var label: String {
        switch self {
        case .recording: return "Snimka i transkripti"
        case .entry(let value): return value.kind.label + " · " + value.certainty.label
        case .note: return "Bilješka"
        case .task(let value): return "Zadatak · " + value.status.rawValue
        case .issue(let value): return "Problem · " + value.status.rawValue
        case .phase: return "Povijest faze"
        }
    }
    var icon: String {
        switch self {
        case .recording: return "waveform"
        case .entry: return "brain.head.profile"
        case .note: return "note.text"
        case .task: return "checklist"
        case .issue: return "exclamationmark.triangle"
        case .phase: return "clock.arrow.circlepath"
        }
    }
}

@MainActor struct MemoryView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var audio = LongRecordingService.shared
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var recordings: [RecordingSession]
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var entries: [MemoryEntry]
    @Query(sort: \ProjectNote.createdAt, order: .reverse) private var notes: [ProjectNote]
    @Query(sort: \ProjectTask.createdAt, order: .reverse) private var tasks: [ProjectTask]
    @Query(sort: \ProjectIssue.createdAt, order: .reverse) private var issues: [ProjectIssue]
    @Query(sort: \PhaseChange.changedAt, order: .reverse) private var phases: [PhaseChange]
    @State private var search = ""
    @State private var projectID: UUID?
    @State private var showNote = false
    @State private var showRecording = false
    @State private var recoveryError: String?

    private var timeline: [MemoryTimelineItem] {
        var all = recordings.map(MemoryTimelineItem.recording)
        all.append(contentsOf: entries.map(MemoryTimelineItem.entry))
        all.append(contentsOf: notes.map(MemoryTimelineItem.note))
        all.append(contentsOf: tasks.map(MemoryTimelineItem.task))
        all.append(contentsOf: issues.map(MemoryTimelineItem.issue))
        all.append(contentsOf: phases.map(MemoryTimelineItem.phase))
        return all.filter { item in
            (projectID == nil || item.project?.id == projectID) &&
            (search.isEmpty || [item.title, item.detail, item.project?.name ?? "", item.label]
                .contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                if let recoveryError {
                    Section("Oporavak snimki") { Text(recoveryError).foregroundStyle(.orange) }
                }
                ForEach(audio.recoveryWarnings, id: \.self) { warning in
                    Section("Oporavak snimki") { Text(warning).font(.footnote).foregroundStyle(.orange) }
                }
                Section {
                    Picker("Projekt", selection: $projectID) {
                        Text("Svi projekti").tag(Optional<UUID>.none)
                        ForEach(projects) { project in
                            Text(project.name + (project.isArchived ? " · arhiviran" : "")).tag(Optional(project.id))
                        }
                    }
                } footer: {
                    Text("Kronologija uključuje sve izvorne snimke, verzije transkripata, bilješke i potvrđene informacije. Pretražuju se i arhivirani projekti.")
                }
                if timeline.isEmpty {
                    ContentUnavailableView("Nema zapisa", systemImage: "brain.head.profile",
                        description: Text("Snimite razgovor, dodajte bilješku ili prilagodite pretraživanje."))
                }
                ForEach(timeline) { item in
                    NavigationLink { MemoryTimelineDestination(item: item) } label: {
                        MemoryTimelineRow(item: item)
                    }
                }
            }
            .navigationTitle("Memorija")
            .task {
                do { _ = try audio.recoverSessions(context: context) }
                catch { recoveryError = "Oporavak nije dovršen. Datoteke ostaju sačuvane: " + error.localizedDescription }
            }
            .searchable(text: $search, prompt: "Svi zapisi i cjeloviti transkripti")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showRecording = true } label: { Label("Nova snimka", systemImage: "mic") }
                    Button { showNote = true } label: { Label("Nova bilješka", systemImage: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showNote) { NoteEditor() }
            .sheet(isPresented: $showRecording) { LongRecordingView() }
        }
    }
}

struct MemoryTimelineRow: View {
    let item: MemoryTimelineItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline).lineLimit(3)
                Text(item.label).font(.caption).foregroundStyle(.secondary)
                if let project = item.project {
                    Text(project.name + (project.isArchived ? " · arhiviran" : "")).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(item.date, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}

struct MemoryTimelineDestination: View {
    let item: MemoryTimelineItem
    @ViewBuilder var body: some View {
        switch item {
        case .recording(let value): RecordingDetailView(recording: value)
        case .entry(let value): MemoryEntryDetailView(entry: value)
        case .note(let value): NoteMemoryDetailView(note: value)
        case .task(let value): LegacyMemoryDetailView(task: value)
        case .issue(let value): LegacyMemoryDetailView(issue: value)
        case .phase(let value):
            Form {
                LabeledContent("Faza", value: value.phase.rawValue)
                Text(value.changedAt, format: .dateTime.day().month().year().hour().minute())
            }.navigationTitle("Promjena faze")
        }
    }
}

struct MemoryEntryDetailView: View {
    let entry: MemoryEntry
    @Query private var memory: [MemoryEntry]
    var body: some View {
        Form {
            Section("Potvrđeni zapis") {
                Text(entry.title).font(.headline)
                Text(entry.details).textSelection(.enabled)
                LabeledContent("Vrsta", value: entry.kind.label)
                LabeledContent("Pouzdanost", value: entry.certainty.label)
                Text(entry.createdAt, format: .dateTime.day().month().year().hour().minute())
                if let responsible = entry.responsible { LabeledContent("Odgovorna osoba", value: responsible) }
                if let due = entry.dueDate { LabeledContent("Rok") { Text(due, format: .dateTime.day().month().year()) } }
            }
            if let project = entry.project {
                Section { NavigationLink(project.name) { ProjectDetailView(project: project) } }
            }
            Section("Izvorni dokaz") {
                Text(entry.quote).textSelection(.enabled)
                if let transcript = entry.transcript {
                    Text("Transkript, verzija \(transcript.revision)").font(.caption)
                    Text(transcript.createdAt, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                    DisclosureGroup("Cjeloviti izvorni transkript") { Text(transcript.text).textSelection(.enabled) }
                    if let recording = transcript.recording {
                        NavigationLink("Otvori snimku i sve verzije") { RecordingDetailView(recording: recording) }
                    }
                }
            }
            if let previous = entry.relatedEntryID {
                Section("Prethodni događaj") {
                    if let related = memory.first(where: { $0.id == previous }) {
                        NavigationLink { MemoryEntryDetailView(entry: related) } label: {
                            VStack(alignment: .leading) {
                                Text(related.title)
                                Text(related.createdAt, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                            }
                        }
                    } else { Text("Prethodni zapis više nije dostupan.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            let later = memory.filter { $0.relatedEntryID == entry.id }.sorted { $0.createdAt < $1.createdAt }
            if !later.isEmpty {
                Section("Kasniji događaji") {
                    ForEach(later) { related in
                        NavigationLink { MemoryEntryDetailView(entry: related) } label: {
                            VStack(alignment: .leading) {
                                Text(related.title)
                                Text(related.createdAt, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(entry.kind.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NoteMemoryDetailView: View {
    let note: ProjectNote
    @State private var editing = false
    var body: some View {
        Form {
            Section("Bilješka") {
                Text(note.text).textSelection(.enabled)
                Text(note.createdAt, format: .dateTime.day().month().year().hour().minute()).foregroundStyle(.secondary)
            }
            if let source = note.sourceTranscript {
                Section("Izvorni diktat") { Text(source).textSelection(.enabled) }
            }
            if let project = note.project { Section { NavigationLink(project.name) { ProjectDetailView(project: project) } } }
        }
        .navigationTitle("Bilješka")
        .toolbar { Button("Uredi") { editing = true } }
        .sheet(isPresented: $editing) { NoteEditor(note: note) }
    }
}

struct LegacyMemoryDetailView: View {
    var task: ProjectTask? = nil
    var issue: ProjectIssue? = nil
    @State private var editing = false
    var body: some View {
        Form {
            if let task {
                Section("Zadatak") {
                    Text(task.title).font(.headline); Text(task.details).textSelection(.enabled)
                    LabeledContent("Status", value: task.status.rawValue)
                    LabeledContent("Prioritet", value: task.priority.rawValue)
                    if let responsible = task.responsible { LabeledContent("Odgovorna osoba", value: responsible) }
                    if let due = task.dueDate { Text(due, format: .dateTime.day().month().year()) }
                    Text(task.createdAt, format: .dateTime.day().month().year().hour().minute())
                }
            }
            if let issue {
                Section("Problem") {
                    Text(issue.title).font(.headline); Text(issue.details).textSelection(.enabled)
                    LabeledContent("Status", value: issue.status.rawValue)
                    Text(issue.resolution).textSelection(.enabled)
                    Text(issue.createdAt, format: .dateTime.day().month().year().hour().minute())
                }
            }
        }
        .navigationTitle(task == nil ? "Problem" : "Zadatak")
        .toolbar { Button("Uredi") { editing = true } }
        .sheet(isPresented: $editing) {
            if let task { TaskEditor(task: task) }
            else if let issue { IssueEditor(issue: issue) }
        }
    }
}
