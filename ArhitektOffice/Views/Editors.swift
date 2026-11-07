import SwiftUI
import SwiftData

private struct ProjectSelector: View {
    let projects: [Project]
    @Binding var selection: UUID?

    var body: some View {
        Picker("Projekt", selection: $selection) {
            Text("Odaberite projekt").tag(Optional<UUID>.none)
            ForEach(projects) { project in
                Text(project.name + (project.isArchived ? " · arhiviran" : "")).tag(Optional(project.id))
            }
        }
        if projects.isEmpty {
            Text("Prvo dodajte projekt na kartici Projekti.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct SourceMemorySection: View {
    let memoryID: UUID?
    @Query private var entries: [MemoryEntry]
    var body: some View {
        if let memoryID, let entry = entries.first(where: { $0.id == memoryID }) {
            Section("Izvor informacije") {
                NavigationLink("Potvrđeni zapis i izvorni transkript") { MemoryEntryDetailView(entry: entry) }
            }
        }
    }
}

struct ProjectEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    var project: Project?
    @State private var name = ""
    @State private var number = ""
    @State private var investor = ""
    @State private var location = ""
    @State private var buildingType = ""
    @State private var phase = ProjectPhase.conditions
    @State private var startedAt = Date()
    @State private var loaded = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Osnovni podaci") {
                    TextField("Naziv projekta", text: $name)
                    TextField("Broj projekta", text: $number)
                    TextField("Investitor", text: $investor)
                    TextField("Lokacija", text: $location)
                    TextField("Vrsta građevine", text: $buildingType)
                }
                Section("Tijek projekta") {
                    Picker("Faza", selection: $phase) {
                        ForEach(ProjectPhase.allCases) { Text($0.rawValue).tag($0) }
                    }
                    DatePicker("Datum početka", selection: $startedAt, displayedComponents: .date)
                }
            }
            .navigationTitle(project == nil ? "Novi projekt" : "Uredi projekt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Odustani") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spremi", action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                guard let project else { return }
                name = project.name; number = project.number; investor = project.investor
                location = project.location; buildingType = project.buildingType
                phase = project.phase; startedAt = project.startedAt
            }
            .alert("Spremanje nije uspjelo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("U redu", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let project {
            project.name = value; project.number = number; project.investor = investor
            project.location = location; project.buildingType = buildingType; project.startedAt = startedAt
            project.changePhase(to: phase)
            project.touch()
        } else {
            modelContext.insert(Project(name: value, number: number, investor: investor, location: location,
                                        buildingType: buildingType, phase: phase, startedAt: startedAt))
        }
        do { try modelContext.save(); dismiss() }
        catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }
}

struct TaskEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]
    var task: ProjectTask?
    var project: Project?
    @State private var title = ""
    @State private var details = ""
    @State private var responsible = ""
    @State private var projectID: UUID?
    @State private var priority = TaskPriority.normal
    @State private var status = TaskStatus.open
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    private var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && projects.contains { $0.id == projectID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Zadatak") {
                    TextField("Naziv zadatka", text: $title, axis: .vertical)
                    TextField("Opis", text: $details, axis: .vertical).lineLimit(3...8)
                    TextField("Odgovorna osoba (neobvezno)", text: $responsible)
                    ProjectSelector(projects: projects, selection: $projectID)
                }
                Section("Organizacija") {
                    Picker("Prioritet", selection: $priority) {
                        ForEach(TaskPriority.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(TaskStatus.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Zadatak ima rok", isOn: $hasDueDate)
                    if hasDueDate { DatePicker("Rok", selection: $dueDate, displayedComponents: .date) }
                }
                if let task {
                    Section { LabeledContent("Evidentirano") { Text(task.createdAt, format: .dateTime.day().month().year().hour().minute()) } }
                    SourceMemorySection(memoryID: task.sourceMemoryID)
                    Section { Button("Obriši zadatak", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(task == nil ? "Novi zadatak" : "Uredi zadatak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Odustani") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Spremi", action: save).disabled(!valid) }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                projectID = task?.project?.id ?? project?.id
                guard let task else { return }
                title = task.title; details = task.details; priority = task.priority; status = task.status
                responsible = task.responsible ?? ""
                hasDueDate = task.dueDate != nil; dueDate = task.dueDate ?? Date()
            }
            .confirmationDialog("Trajno obrisati zadatak?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Obriši zadatak", role: .destructive, action: delete)
                Button("Odustani", role: .cancel) {}
            }
            .alert("Spremanje nije uspjelo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("U redu", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard valid, let selectedProject = projects.first(where: { $0.id == projectID }) else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record: ProjectTask
        if let task {
            task.project?.touch()
            record = task
            record.title = value; record.details = details; record.dueDate = hasDueDate ? dueDate : nil
            record.priority = priority; record.project = selectedProject
        } else {
            record = ProjectTask(title: value, details: details, dueDate: hasDueDate ? dueDate : nil, priority: priority, project: selectedProject)
            modelContext.insert(record)
        }
        record.status = status
        let person = responsible.trimmingCharacters(in: .whitespacesAndNewlines)
        record.responsible = person.isEmpty ? nil : person
        selectedProject.touch()
        do { try modelContext.save(); dismiss() }
        catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }

    private func delete() {
        guard let task else { return }
        task.project?.touch()
        modelContext.delete(task)
        do { try modelContext.save(); dismiss() }
        catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }
}

struct IssueEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]
    var issue: ProjectIssue?
    var project: Project?
    @State private var title = ""
    @State private var details = ""
    @State private var resolution = ""
    @State private var projectID: UUID?
    @State private var status = IssueStatus.open
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    private var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && projects.contains { $0.id == projectID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Problem") {
                    TextField("Naziv problema", text: $title, axis: .vertical)
                    TextField("Opis problema", text: $details, axis: .vertical).lineLimit(3...8)
                    ProjectSelector(projects: projects, selection: $projectID)
                    Picker("Status", selection: $status) {
                        ForEach(IssueStatus.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Rješenje") {
                    TextField("Opis rješenja ili dosadašnjih koraka", text: $resolution, axis: .vertical).lineLimit(3...10)
                }
                if let issue {
                    Section { LabeledContent("Evidentirano") { Text(issue.createdAt, format: .dateTime.day().month().year().hour().minute()) } }
                    SourceMemorySection(memoryID: issue.sourceMemoryID)
                    Section { Button("Obriši problem", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(issue == nil ? "Novi problem" : "Uredi problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Odustani") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Spremi", action: save).disabled(!valid) }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                projectID = issue?.project?.id ?? project?.id
                guard let issue else { return }
                title = issue.title; details = issue.details; resolution = issue.resolution; status = issue.status
            }
            .confirmationDialog("Trajno obrisati problem?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Obriši problem", role: .destructive, action: delete)
                Button("Odustani", role: .cancel) {}
            }
            .alert("Spremanje nije uspjelo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("U redu", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard valid, let selectedProject = projects.first(where: { $0.id == projectID }) else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record: ProjectIssue
        if let issue {
            issue.project?.touch()
            record = issue; record.title = value; record.details = details; record.project = selectedProject
        } else {
            record = ProjectIssue(title: value, details: details, project: selectedProject)
            modelContext.insert(record)
        }
        record.status = status; record.resolution = resolution
        selectedProject.touch()
        do { try modelContext.save(); dismiss() }
        catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }

    private func delete() {
        guard let issue else { return }
        issue.project?.touch(); modelContext.delete(issue)
        do { try modelContext.save(); dismiss() }
        catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }
}

struct NoteEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]
    var note: ProjectNote?
    var project: Project?
    @State private var text = ""
    @State private var projectID: UUID?
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    private var valid: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && projects.contains { $0.id == projectID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bilješka") {
                    ProjectSelector(projects: projects, selection: $projectID)
                    TextField("Tekst bilješke", text: $text, axis: .vertical).lineLimit(8...20)
                }
                if let note {
                    SourceMemorySection(memoryID: note.sourceMemoryID)
                    Section("Datumi") {
                        LabeledContent("Evidentirano") { Text(note.createdAt, format: .dateTime.day().month().year().hour().minute()) }
                        LabeledContent("Uređeno") { Text(note.modifiedAt, format: .dateTime.day().month().year().hour().minute()) }
                    }
                    if let original = note.sourceTranscript {
                        Section {
                            Text(original).textSelection(.enabled)
                        } header: {
                            Text("Izvorni diktat")
                        } footer: {
                            Text("Izvorni tekst čuva se neovisno o uređivanju i razvrstavanju bilješke.")
                        }
                    }
                    Section { Button("Obriši bilješku", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(note == nil ? "Nova bilješka" : "Uredi bilješku")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Odustani") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Spremi", action: save).disabled(!valid) }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                projectID = note?.project?.id ?? project?.id
                text = note?.text ?? ""
            }
            .confirmationDialog("Trajno obrisati bilješku?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Obriši bilješku", role: .destructive, action: delete)
                Button("Odustani", role: .cancel) {}
            }
            .alert("Spremanje nije uspjelo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("U redu", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard valid, let selectedProject = projects.first(where: { $0.id == projectID }) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note {
            note.project?.touch(); note.text = value; note.project = selectedProject; note.modifiedAt = Date()
        } else {
            modelContext.insert(ProjectNote(text: value, project: selectedProject))
        }
        selectedProject.touch()
        do { try modelContext.save(); dismiss() }
        catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }

    private func delete() {
        guard let note else { return }
        note.project?.touch(); modelContext.delete(note)
        do { try modelContext.save(); dismiss() }
        catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }
}
