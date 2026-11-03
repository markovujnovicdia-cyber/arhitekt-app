import SwiftUI
import SwiftData

struct IssuesView: View {
    @Query(sort: \ProjectIssue.createdAt, order: .reverse) private var issues: [ProjectIssue]
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var search = ""
    @State private var status: IssueStatus? = .open
    @State private var projectID: UUID?
    @State private var showEditor = false
    @State private var selectedIssue: ProjectIssue?

    private var filtered: [ProjectIssue] {
        issues.filter { issue in
            (status == nil || issue.status == status) &&
            (projectID == nil || issue.project?.id == projectID) &&
            (search.isEmpty || issue.title.localizedCaseInsensitiveContains(search) || issue.details.localizedCaseInsensitiveContains(search) || issue.resolution.localizedCaseInsensitiveContains(search) || (issue.project?.name.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Status", selection: $status) {
                        Text("Svi").tag(Optional<IssueStatus>.none)
                        ForEach(IssueStatus.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }.pickerStyle(.segmented)
                    Picker("Projekt", selection: $projectID) {
                        Text("Svi projekti").tag(Optional<UUID>.none)
                        ForEach(projects) { Text($0.name + ($0.isArchived ? " · arhiviran" : "")).tag(Optional($0.id)) }
                    }
                }
                if filtered.isEmpty {
                    ContentUnavailableView("Nema problema", systemImage: "checkmark.shield", description: Text("Nema problema koji odgovaraju odabranim filtrima."))
                }
                ForEach(filtered) { issue in
                    Button { selectedIssue = issue } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: issue.status == .resolved ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.title3).foregroundStyle(issue.status == .resolved ? Color.green : Color.orange)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(issue.title).font(.headline).foregroundStyle(.primary)
                                Text(issue.project?.name ?? "Projekt nije dodijeljen").font(.subheadline).foregroundStyle(.secondary)
                                Text(issue.details).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                HStack {
                                    Text(issue.status.rawValue)
                                    Text(issue.createdAt, format: .dateTime.day().month().year())
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }
            .navigationTitle("Problemi")
            .searchable(text: $search, prompt: "Pretraži probleme i rješenja")
            .toolbar { Button { showEditor = true } label: { Label("Novi problem", systemImage: "plus") } }
            .sheet(isPresented: $showEditor) { IssueEditor() }
            .sheet(item: $selectedIssue) { IssueEditor(issue: $0) }
        }
    }
}
