import SwiftUI
import SwiftData

private enum DueFilter: String, CaseIterable, Identifiable {
    case all = "Svi rokovi", overdue = "Prekoračen rok", today = "Danas", week = "Sljedećih 7 dana", none = "Bez roka"
    var id: String { rawValue }
    func matches(_ date: Date?) -> Bool {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        switch self {
        case .all: return true
        case .none: return date == nil
        case .overdue: return date.map { $0 < start } ?? false
        case .today: return date.map { calendar.isDateInToday($0) } ?? false
        case .week:
            guard let date, let end = calendar.date(byAdding: .day, value: 7, to: start) else { return false }
            return date >= start && date < end
        }
    }
}

struct TasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProjectTask.createdAt, order: .reverse) private var tasks: [ProjectTask]
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var search = ""
    @State private var projectID: UUID?
    @State private var status: TaskStatus? = .open
    @State private var priority: TaskPriority?
    @State private var dueFilter = DueFilter.all
    @State private var showFilters = false
    @State private var showEditor = false
    @State private var selectedTask: ProjectTask?
    @State private var errorMessage: String?

    private var filtered: [ProjectTask] {
        tasks.filter { task in
            (projectID == nil || task.project?.id == projectID) &&
            (status == nil || task.status == status) &&
            (priority == nil || task.priority == priority) &&
            dueFilter.matches(task.dueDate) &&
            (search.isEmpty || task.title.localizedCaseInsensitiveContains(search) || task.details.localizedCaseInsensitiveContains(search) || (task.project?.name.localizedCaseInsensitiveContains(search) ?? false))
        }.sorted { left, right in
            let leftDate = left.dueDate ?? .distantFuture
            let rightDate = right.dueDate ?? .distantFuture
            return leftDate == rightDate ? left.createdAt > right.createdAt : leftDate < rightDate
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Status", selection: $status) {
                        Text("Svi").tag(Optional<TaskStatus>.none)
                        ForEach(TaskStatus.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }.pickerStyle(.segmented)
                }
                if showFilters {
                    Section("Filtri") {
                        Picker("Projekt", selection: $projectID) {
                            Text("Svi projekti").tag(Optional<UUID>.none)
                            ForEach(projects) { Text($0.name + ($0.isArchived ? " · arhiviran" : "")).tag(Optional($0.id)) }
                        }
                        Picker("Prioritet", selection: $priority) {
                            Text("Svi prioriteti").tag(Optional<TaskPriority>.none)
                            ForEach(TaskPriority.allCases) { Text($0.rawValue).tag(Optional($0)) }
                        }
                        Picker("Rok", selection: $dueFilter) {
                            ForEach(DueFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Button("Poništi filtre") { projectID = nil; priority = nil; dueFilter = .all; status = .open }
                    }
                }
                if filtered.isEmpty {
                    ContentUnavailableView("Nema zadataka", systemImage: "checklist", description: Text("Dodajte zadatak ili prilagodite filtre."))
                }
                ForEach(filtered) { task in
                    Button { selectedTask = task } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(task.status == .completed ? Color.green : Color.accentColor)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.title).font(.headline).foregroundStyle(.primary)
                                    .strikethrough(task.status == .completed)
                                Text(task.project?.name ?? "Projekt nije dodijeljen").font(.subheadline).foregroundStyle(.secondary)
                                if let responsible = task.responsible, !responsible.isEmpty {
                                    Label(responsible, systemImage: "person").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(task.priority.rawValue)
                                        .foregroundStyle(task.priority == .high ? Color.orange : Color.secondary)
                                    if let date = task.dueDate {
                                        Text(date, format: .dateTime.day().month().year())
                                            .foregroundStyle(isOverdue(task) ? Color.red : Color.secondary)
                                    }
                                }.font(.caption)
                            }
                        }.padding(.vertical, 5)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            task.status = task.status == .open ? .completed : .open
                            task.project?.touch()
                            do { try modelContext.save() }
                            catch { modelContext.rollback(); errorMessage = error.localizedDescription }
                        } label: {
                            Label(task.status == .open ? "Izvrši" : "Ponovno otvori", systemImage: task.status == .open ? "checkmark" : "arrow.uturn.backward")
                        }.tint(.green)
                    }
                }
            }
            .navigationTitle("Zadaci")
            .searchable(text: $search, prompt: "Pretraži zadatke")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showFilters.toggle() } label: {
                        Label("Filtri", systemImage: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) { Button { showEditor = true } label: { Label("Novi zadatak", systemImage: "plus") } }
            }
            .sheet(isPresented: $showEditor) { TaskEditor() }
            .sheet(item: $selectedTask) { TaskEditor(task: $0) }
            .alert("Spremanje nije uspjelo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("U redu", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func isOverdue(_ task: ProjectTask) -> Bool {
        task.status == .open && (task.dueDate.map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false)
    }
}
