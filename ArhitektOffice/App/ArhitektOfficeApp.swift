import SwiftUI
import SwiftData

@main
struct ArhitektOfficeApp: App {
    private let container: ModelContainer?
    private let storageError: String?

    init() {
        do {
            // Explicitly local today. CloudKit-compatible models can later be migrated
            // to an opt-in cloud configuration without changing view ownership.
            let schema = Schema([Project.self, ProjectTask.self, ProjectIssue.self,
                                 ProjectNote.self, PhaseChange.self])
            let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            container = try ModelContainer(for: schema, configurations: [configuration])
            storageError = nil
        } catch {
            container = nil
            storageError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                RootView().modelContainer(container)
                    .environment(\.locale, Locale(identifier: "hr_HR"))
            } else {
                ContentUnavailableView {
                    Label("Bazu nije moguće otvoriti", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Podaci nisu obrisani. Ponovno pokrenite aplikaciju ili provjerite slobodan prostor na uređaju.\n\n\(storageError ?? "Nepoznata pogreška")")
                }
            }
        }
    }
}

struct RootView: View {
    @State private var showDictation = false
    @State private var showSettings = false

    var body: some View {
        TabView {
            ProjectsView().tabItem { Label("Projekti", systemImage: "building.2") }
            TasksView().tabItem { Label("Zadaci", systemImage: "checklist") }
            IssuesView().tabItem { Label("Problemi", systemImage: "exclamationmark.bubble") }
            NotesView().tabItem { Label("Bilješke", systemImage: "note.text") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").frame(minWidth: 48, minHeight: 48)
                }
                .accessibilityLabel("Postavke i sigurnosne kopije")
                Spacer()
                Button { showDictation = true } label: {
                    Label("Diktiraj bilješku", systemImage: "mic.fill")
                        .font(.headline).frame(minHeight: 48).padding(.horizontal, 18)
                }
                .buttonStyle(.borderedProminent).clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 8).background(.bar)
        }
        .sheet(isPresented: $showDictation) { DictationView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}
