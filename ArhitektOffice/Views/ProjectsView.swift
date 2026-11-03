import SwiftUI
import SwiftData

struct ProjectsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.lastActivity, order: .reverse) private var projects: [Project]
    @State private var search = ""
    @State private var showArchived = false
    @State private var showEditor = false
    @State private var errorMessage: String?

    private var visibleProjects: [Project] {
        projects.filter { project in
            project.isArchived == showArchived && (search.isEmpty ||
                [project.name, project.number, project.investor, project.location, project.buildingType]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Prikaz", selection: $showArchived) {
                    Text("Aktivni").tag(false)
                    Text("Arhivirani").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if visibleProjects.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "Nema projekata" : "Nema rezultata",
                                           systemImage: "building.2",
                                           description: Text(search.isEmpty ? "Dodajte projekt tipkom +." : "Pokušajte drugi pojam za pretraživanje."))
                }
                ForEach(visibleProjects) { project in
                    NavigationLink {
                        ProjectDetailView(project: project)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(project.name).font(.headline)
                                Spacer()
                                Text(project.number).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(project.phase.rawValue)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.tint)
                            if !project.location.isEmpty {
                                Label(project.location, systemImage: "mappin.and.ellipse")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 16) {
                                Label("Zadaci: \(project.openTaskCount)", systemImage: "checklist")
                                    .foregroundStyle(.secondary)
                                Label("Problemi: \(project.openIssueCount)", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(project.openIssueCount > 0 ? Color.orange : Color.secondary)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 6)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            project.isArchived.toggle()
                            project.touch()
                            do { try modelContext.save() }
                            catch { modelContext.rollback(); errorMessage = error.localizedDescription }
                        } label: {
                            Label(showArchived ? "Vrati" : "Arhiviraj", systemImage: showArchived ? "tray.and.arrow.up" : "archivebox")
                        }.tint(.indigo)
                    }
                }
            }
            .navigationTitle("Projekti")
            .searchable(text: $search, prompt: "Naziv, broj, investitor, lokacija")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showEditor = true } label: { Label("Novi projekt", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showEditor) { ProjectEditor() }
            .alert("Spremanje nije uspjelo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("U redu", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}
