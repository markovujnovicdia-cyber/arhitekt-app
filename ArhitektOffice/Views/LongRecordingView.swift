import SwiftData
import SwiftUI
import UIKit

@MainActor
struct LongRecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Project.name) private var projects: [Project]
    @ObservedObject private var audio = LongRecordingService.shared
    @State private var selectedProjectID: UUID?
    @State private var title = "Sastanak / razgovor"
    @State private var startTask: Task<Void, Never>?
    @State private var detailSession: RecordingSession?
    @State private var showFinishConfirmation = false

    init(project: Project? = nil) { _selectedProjectID = State(initialValue: project?.id) }

    private var isActive: Bool { audio.state == .recording || audio.state == .paused }
    private var isBusy: Bool { isActive || audio.state == .preparing }
    private var activeProjects: [Project] { projects.filter { !$0.isArchived } }

    var body: some View {
        NavigationStack {
            Form {
                if !isBusy {
                    Section("Nova snimka") {
                        TextField("Naslov snimke", text: $title)
                        Picker("Projekt", selection: $selectedProjectID) {
                            Text("Odabrat ću kasnije").tag(nil as UUID?)
                            ForEach(activeProjects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                    }
                }
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: audio.state == .recording ? "waveform.circle.fill" : "mic.circle")
                            .font(.system(size: 64))
                            .foregroundStyle(audio.state == .recording ? .red : .primary)
                            .accessibilityHidden(true)
                        Text(formattedDuration(audio.elapsed))
                            .font(.system(.largeTitle, design: .monospaced))
                            .monospacedDigit()
                            .accessibilityLabel("Trajanje snimke: \(formattedDuration(audio.elapsed))")
                        Text(statusTitle).font(.headline)
                        if isActive, let session = audio.currentSession {
                            Text(session.title).foregroundStyle(.secondary)
                            if let project = session.project { Text(project.name).font(.subheadline) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    controls
                } footer: {
                    Text("Zvuk se kontinuirano sprema na ovaj iPhone. Snimanje radi bez interneta i nastavlja se nakon zaključavanja zaslona. Poziv ili odspajanje mikrofona pauzira snimanje; nastavite ručno nakon prekida. U ovu snimku ne sprema se zvuk telefonskog poziva.")
                }
                if let error = audio.errorMessage {
                    Section("Obavijest") {
                        Text(error).foregroundStyle(.red)
                        Button("Postavke mikrofona") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
                if !isBusy, let session = audio.currentSession {
                    Section("Sačuvana snimka") {
                        Button("Otvori snimku i transkripte", systemImage: "doc.text.magnifyingglass") {
                            detailSession = session
                        }
                        if session.masterRelativePath != nil {
                            Button(audio.playingSessionID == session.id ? "Zaustavi reprodukciju" : "Preslušaj snimku",
                                   systemImage: audio.playingSessionID == session.id ? "stop.fill" : "play.fill") {
                                do {
                                    if audio.playingSessionID == session.id { audio.stopPlayback() }
                                    else { try audio.play(session) }
                                } catch { audio.errorMessage = error.localizedDescription }
                            }
                        }
                    }
                }
                Section("Privatnost i obrada") {
                    Label("Snimanje ne šalje zvuk na internet.", systemImage: "lock.shield")
                    Text("Nakon završetka otvorite snimku, pregledajte je i izričito dopustite cloud obradu ako želite transkripciju i AI analizu. Za njih je potreban konfiguriran backend i internet. Izvorni audio ostaje sačuvan čak i ako obrada ne uspije.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dugo snimanje")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zatvori") {
                        if isActive { showFinishConfirmation = true } else { dismiss() }
                    }
                    .disabled(audio.state == .preparing)
                }
            }
            .confirmationDialog("Završiti i sačuvati snimku?", isPresented: $showFinishConfirmation, titleVisibility: .visible) {
                Button("Završi i zatvori") {
                    do { try audio.finish(); dismiss() }
                    catch { audio.errorMessage = error.localizedDescription }
                }
                Button("Nastavi snimanje", role: .cancel) { }
            } message: {
                Text("Sve do sada snimljeno ostaje na uređaju. Transkripciju možete pokrenuti kasnije iz Memorije.")
            }
            .sheet(item: $detailSession) { recording in
                NavigationStack { RecordingDetailView(recording: recording, showsCloseButton: true) }
            }
            .interactiveDismissDisabled(isBusy)
            .onChange(of: scenePhase) { _, phase in
                // Keep an active local recording running when the phone locks.
                // Only cancel a not-yet-started permission request on background.
                if phase == .background, audio.state == .preparing { startTask?.cancel() }
            }
            .onDisappear {
                if audio.state == .preparing { startTask?.cancel() }
                if !isActive { audio.stopPlayback() }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch audio.state {
        case .preparing:
            HStack { ProgressView(); Text("Priprema mikrofona i pohrane…") }
        case .recording:
            actionButton("Pauziraj", symbol: "pause.fill") { audio.pause() }
            actionButton("Završi i sačuvaj", symbol: "stop.fill", tint: .red, action: finish)
        case .paused:
            actionButton("Nastavi", symbol: "mic.fill") {
                do { try audio.resume() } catch { audio.errorMessage = error.localizedDescription }
            }
            actionButton("Završi i sačuvaj", symbol: "stop.fill", tint: .red, action: finish)
        case .idle, .finished:
            actionButton("Započni snimanje", symbol: "mic.fill") {
                guard scenePhase == .active else { return }
                let project = activeProjects.first { $0.id == selectedProjectID }
                startTask = Task { @MainActor in
                    await audio.start(project: project, context: modelContext, title: title)
                }
            }
        }
    }

    private func actionButton(_ title: String, symbol: String, tint: Color = .accentColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tint(tint)
    }

    private func finish() {
        do {
            try audio.finish()
            detailSession = audio.currentSession
        } catch { audio.errorMessage = "Zvuk ostaje na uređaju. \(error.localizedDescription)" }
    }

    private var statusTitle: String {
        switch audio.state {
        case .idle: "Spremno za snimanje"
        case .preparing: "Priprema"
        case .recording: "Snimanje na uređaju"
        case .paused: "Pauzirano — zvuk je sačuvan"
        case .finished: "Snimka je sačuvana"
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
