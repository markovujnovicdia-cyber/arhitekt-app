import SwiftUI
import SwiftData
import Security

@main
@MainActor
struct ArhitektOfficeApp: App {
    private let container: ModelContainer?
    private let storageError: String?

    init() {
        do {
            // Explicitly local today. CloudKit-compatible models can later be migrated
            // to an opt-in cloud configuration without changing view ownership.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: support.path)
            var excludedSupport = support
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excludedSupport.setResourceValues(values)
            // Remove previously stored backend access without reading credentials.
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "com.arhitektoffice.backend-access"] as CFDictionary)
            UserDefaults.standard.removeObject(forKey: "office.ai.backendURL")
            let schema = Schema([Project.self, ProjectTask.self, ProjectIssue.self,
                                 ProjectNote.self, PhaseChange.self, RecordingSession.self,
                                 AudioSegment.self, TranscriptVersion.self, MemoryEntry.self])
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

@MainActor
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var recoveryChecked = false
    @State private var recoveryError: String?
    @State private var showDictation = false
    @State private var showSettings = false

    var body: some View {
        TabView {
            ProjectsView().tabItem { Label("Projekti", systemImage: "building.2") }
            TasksView().tabItem { Label("Zadaci", systemImage: "checklist") }
            IssuesView().tabItem { Label("Problemi", systemImage: "exclamationmark.bubble") }
            MemoryView().tabItem { Label("Memorija", systemImage: "clock.arrow.circlepath") }
            AskOfficeView().tabItem { Label("Pitaj ured", systemImage: "bubble.left.and.bubble.right") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").frame(minWidth: 48, minHeight: 48)
                }
                .accessibilityLabel("Postavke i sigurnosne kopije")
                Spacer()
                Button { showDictation = true } label: {
                    Label("Snimi razgovor", systemImage: "mic.fill")
                        .font(.headline).frame(minHeight: 48).padding(.horizontal, 18)
                }
                .buttonStyle(.borderedProminent).clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 8).background(.bar)
        }
        .sheet(isPresented: $showDictation) { LongRecordingView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            guard !recoveryChecked else { return }
            recoveryChecked = true
            do {
                try LongRecordingService.shared.recoverSessions(context: modelContext)
                let warnings = LongRecordingService.shared.recoveryWarnings
                if !warnings.isEmpty { recoveryError = warnings.joined(separator: "\n") }
            } catch { recoveryError = "Oporavak snimki nije dovršen. Datoteke nisu obrisane. " + error.localizedDescription }
        }
        .alert("Oporavak snimki", isPresented: Binding(get: { recoveryError != nil }, set: { if !$0 { recoveryError = nil } })) {
            Button("U redu", role: .cancel) { recoveryError = nil }
        } message: { Text(recoveryError ?? "") }
    }
}
