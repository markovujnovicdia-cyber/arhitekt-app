import SwiftUI
import SwiftData

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var project: Project
    @State private var showEditor = false
    @State private var showTaskEditor = false
    @State private var showIssueEditor = false
    @State private var showNoteEditor = false
    @State private var showDictation = false
    @State private var selectedTask: ProjectTask?
    @State private var selectedIssue: ProjectIssue?
    @State private var selectedNote: ProjectNote?
    @State private var errorMessage: String?

    private var timeline: [MemoryTimelineItem] {
        var records = project.recordings.map(MemoryTimelineItem.recording)
        records.append(contentsOf: project.memory.map(MemoryTimelineItem.entry))
        records.append(contentsOf: project.notes.map(MemoryTimelineItem.note))
        records.append(contentsOf: project.tasks.map(MemoryTimelineItem.task))
        records.append(contentsOf: project.issues.map(MemoryTimelineItem.issue))
        records.append(contentsOf: project.phaseHistory.map(MemoryTimelineItem.phase))
        return records.sorted { $0.date > $1.date }
    }

    private var currentMemory: [MemoryEntry] {
        let continued = Set(project.memory.compactMap(\.relatedEntryID))
        return project.memory.filter { !continued.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            Section("Trenutačno stanje") {
                LabeledContent("Faza", value: project.phase.rawValue)
                LabeledContent("Otvoreni zadaci", value: String(project.openTaskCount))
                LabeledContent("Neriješeni problemi", value: String(project.openIssueCount))
                LabeledContent("Otvorena pitanja", value: String(currentMemory.filter { $0.kind == .question }.count))
                if let summary = currentMemory.first(where: { $0.kind == .summary }) {
                    NavigationLink { MemoryEntryDetailView(entry: summary) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(summary.details.isEmpty ? summary.title : summary.details)
                            Text(summary.certainty.label).font(.caption).foregroundStyle(.secondary)
                            Text(summary.createdAt, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Sažetak nastaje tek nakon pregleda i potvrde informacija. Izvorna kronologija uvijek ostaje dostupna.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(currentMemory.filter { [.decision, .agreement, .change].contains($0.kind) }.prefix(3))) { entry in
                    NavigationLink { MemoryEntryDetailView(entry: entry) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                            Text(entry.kind.label + " · " + entry.certainty.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !project.isArchived {
                    Button { showDictation = true } label: { Label("Snimi sastanak ili razgovor", systemImage: "mic.fill") }
                }
            }
            Section("Projekt") {
                if !project.number.isEmpty { LabeledContent("Broj", value: project.number) }
                if !project.investor.isEmpty { LabeledContent("Investitor", value: project.investor) }
                if !project.location.isEmpty { LabeledContent("Lokacija", value: project.location) }
                if !project.buildingType.isEmpty { LabeledContent("Vrsta građevine", value: project.buildingType) }
                LabeledContent("Početak") { Text(project.startedAt, format: .dateTime.day().month().year()) }
                LabeledContent("Posljednja aktivnost") { Text(project.lastActivity, format: .dateTime.day().month().year().hour().minute()) }
                Picker("Faza", selection: Binding(get: { project.phase }, set: { phase in
                    project.changePhase(to: phase)
                    save()
                })) {
                    ForEach(ProjectPhase.allCases) { phase in Text(phase.rawValue).tag(phase) }
                }
                if project.isArchived { Label("Arhiviran projekt", systemImage: "archivebox").foregroundStyle(.secondary) }
            }

            Section {
                ForEach(project.tasks.sorted { $0.createdAt > $1.createdAt }) { task in
                    Button { selectedTask = task } label: {
                        HStack(alignment: .top) {
                            Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.status == .completed ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).foregroundStyle(.primary)
                                if let due = task.dueDate {
                                    Text(due, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(task.priority.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button { showTaskEditor = true } label: { Label("Dodaj zadatak", systemImage: "plus.circle") }
            } header: { Text("Zadaci · otvoreno \(project.openTaskCount)") }

            Section {
                ForEach(project.issues.sorted { $0.createdAt > $1.createdAt }) { issue in
                    Button { selectedIssue = issue } label: {
                        HStack(alignment: .top) {
                            Image(systemName: issue.status == .resolved ? "checkmark.seal" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.status == .resolved ? Color.green : Color.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.title).foregroundStyle(.primary)
                                Text(issue.status.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button { showIssueEditor = true } label: { Label("Dodaj problem", systemImage: "plus.circle") }
            } header: { Text("Problemi · neriješeno \(project.openIssueCount)") }

            Section("Bilješke") {
                ForEach(project.notes.sorted { $0.createdAt > $1.createdAt }) { note in
                    Button { selectedNote = note } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.text).foregroundStyle(.primary).lineLimit(4)
                            Text(note.createdAt, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                Button { showNoteEditor = true } label: { Label("Dodaj bilješku", systemImage: "plus.circle") }
            }

            Section("Povijest faza") {
                ForEach(project.phaseHistory.sorted { $0.changedAt > $1.changedAt }) { entry in
                    LabeledContent(entry.phase.rawValue) {
                        Text(entry.changedAt, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption)
                    }
                }
            }
            Section("Cjelovita kronologija") {
                ForEach(timeline) { item in
                    NavigationLink { MemoryTimelineDestination(item: item) } label: { MemoryTimelineRow(item: item) }
                }
            }
            Section {
                Button {
                    project.isArchived.toggle()
                    project.touch()
                    save()
                } label: {
                    Label(project.isArchived ? "Vrati među aktivne projekte" : "Arhiviraj projekt",
                          systemImage: project.isArchived ? "tray.and.arrow.up" : "archivebox")
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !project.isArchived {
                    Button { showDictation = true } label: { Label("Diktiraj za ovaj projekt", systemImage: "mic") }
                }
                Button("Uredi") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) { ProjectEditor(project: project) }
        .sheet(isPresented: $showTaskEditor) { TaskEditor(project: project) }
        .sheet(isPresented: $showIssueEditor) { IssueEditor(project: project) }
        .sheet(isPresented: $showNoteEditor) { NoteEditor(project: project) }
        .sheet(isPresented: $showDictation) { LongRecordingView(project: project) }
        .sheet(item: $selectedTask) { TaskEditor(task: $0) }
        .sheet(item: $selectedIssue) { IssueEditor(issue: $0) }
        .sheet(item: $selectedNote) { NoteEditor(note: $0) }
        .alert("Spremanje nije uspjelo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("U redu", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        do { try modelContext.save() }
        catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }
}
