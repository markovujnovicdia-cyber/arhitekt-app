import SwiftData
import SwiftUI
import UIKit

@MainActor
struct DictationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Project.name) private var projects: [Project]
    @StateObject private var speech = SpeechService()
    @State private var inputText = ""
    @State private var recordingPrefix = ""
    @State private var previousRawRecordings: [String] = []
    @State private var originalText = ""
    @State private var selectedProjectID: UUID?
    @State private var items: [DictationItem] = []
    @State private var isReviewing = false
    @State private var projectHint = ""
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var recordingStartTask: Task<Void, Never>?

    init(project: Project? = nil) {
        _selectedProjectID = State(initialValue: project?.id)
    }

    private var activeProjects: [Project] { projects.filter { !$0.isArchived } }
    private var isBusy: Bool { speech.isRecording || speech.isFinishing || speech.isPreparing }
    private var hasValidItems: Bool {
        !items.isEmpty && items.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if activeProjects.isEmpty {
                    Section {
                        Label("Najprije dodajte ili aktivirajte projekt u kartici Projekti.", systemImage: "folder.badge.plus")
                    }
                }
                if isReviewing { reviewContent } else { captureContent }
                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red) }
                }
            }
            .navigationTitle(isReviewing ? "Potvrdite unos" : "Diktiranje")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isReviewing ? "Natrag" : "Odustani") {
                        if isReviewing { isReviewing = false } else { dismiss() }
                    }
                    .disabled(isSaving)
                }
                if isReviewing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Spremi", action: save)
                            .disabled(selectedProjectID == nil || !hasValidItems || isSaving)
                    }
                }
            }
            .confirmationDialog("Obrada govora putem Applea", isPresented: $speech.requiresNetworkConsent, titleVisibility: .visible) {
                Button("Dopusti za ovo snimanje") { startRecording(allowNetwork: true) }
                Button("Odustani", role: .cancel) { }
            } message: {
                Text("Ovaj uređaj ne podržava lokalno prepoznavanje hrvatskog govora. Uz vašu privolu zvuk se šalje Appleu na obradu i potreban je internet. Možete odustati i tekst upisati ručno, bez slanja podataka.")
            }
            .onChange(of: speech.transcript) { _, text in
                guard !text.isEmpty else { return }
                inputText = [recordingPrefix, text].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    recordingStartTask?.cancel()
                    speech.requiresNetworkConsent = false
                    speech.stop()
                }
            }
            .onDisappear {
                recordingStartTask?.cancel()
                speech.cancel()
            }
            .interactiveDismissDisabled(isBusy || !inputText.isEmpty)
        }
    }

    private var captureContent: some View {
        Group {
            Section {
                TextEditor(text: $inputText)
                    .frame(minHeight: 200)
                    .disabled(isBusy)
                    .accessibilityLabel("Tekst diktata. Možete i ručno upisati tekst.")
                Button {
                    if speech.isRecording { speech.stop() } else { startRecording() }
                } label: {
                    HStack {
                        Spacer()
                        Label(speech.isRecording ? "Zaustavi snimanje" : "Diktiraj na hrvatskom", systemImage: speech.isRecording ? "stop.circle.fill" : "mic.fill")
                            .font(.headline)
                            .padding(.vertical, 10)
                        Spacer()
                    }
                }
                .disabled(speech.isPreparing || speech.isFinishing || activeProjects.isEmpty)
                .tint(speech.isRecording ? .red : .accentColor)
                if speech.isPreparing || speech.isFinishing {
                    HStack {
                        ProgressView()
                        Text(speech.isFinishing ? "Dovršavanje prijepisa…" : "Priprema mikrofona…")
                    }
                }
                if speech.isRecording {
                    Label(speech.usesNetworkRecognition ? "Snimanje • obrada putem Applea" : "Snimanje • obrada na uređaju", systemImage: "waveform")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Izgovorite ili upišite tekst")
            } footer: {
                Text("Navedite naziv ili broj projekta. Razvrstavanje radi lokalno. Prije spremanja provjerite sve prijedloge; rokove i prioritete naknadno uredite u zadacima.")
            }
            if let error = speech.errorMessage {
                Section("Prepoznavanje govora") {
                    Text(error).foregroundStyle(.red)
                    Button("Otvori postavke aplikacije") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            Section {
                Button("Pregledaj i razvrstaj", systemImage: "text.badge.checkmark", action: prepareReview)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy || activeProjects.isEmpty)
            }
        }
    }

    private var reviewContent: some View {
        Group {
            Section {
                Picker("Projekt", selection: $selectedProjectID) {
                    Text("Odaberite projekt").tag(nil as UUID?)
                    ForEach(activeProjects) { project in
                        Text(project.number.isEmpty ? project.name : "\(project.name) (\(project.number))")
                            .tag(Optional(project.id))
                    }
                }
                Text(projectHint).font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Provjerite odredište")
            }
            ForEach($items) { $item in
                Section {
                    Picker("Kategorija", selection: $item.category) {
                        ForEach(DictationCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextEditor(text: $item.text)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Tekst stavke: \(item.category.rawValue)")
                    Button("Ukloni stavku", role: .destructive) {
                        let removedID = item.id
                        items.removeAll { $0.id == removedID }
                    }
                }
            }
            Section {
                Button("Dodaj stavku", systemImage: "plus") {
                    items.append(DictationItem(category: .note, text: ""))
                }
                DisclosureGroup("Izvorni tekst (ostaje sačuvan)") {
                    Text(originalText).textSelection(.enabled)
                }
            } footer: {
                Text("Izvorni tekst sprema se kao zasebna bilješka uz sve potvrđene stavke. Zadaci su otvoreni i srednjeg prioriteta, bez roka. Datum i vrijeme dodaju se automatski.")
            }
        }
    }

    private func startRecording(allowNetwork: Bool = false) {
        guard scenePhase == .active else { return }
        if !allowNetwork { recordingPrefix = inputText.trimmingCharacters(in: .whitespacesAndNewlines) }
        recordingStartTask?.cancel()
        recordingStartTask = Task { @MainActor in
            let previous = speech.transcript
            await speech.start(allowNetworkRecognition: allowNetwork)
            // A failed new audio session can also clear the previous transcript.
            // Preserve it whenever a start attempt replaces it, not only on success.
            if !previous.isEmpty, speech.transcript != previous {
                previousRawRecordings.append(previous)
            }
        }
    }

    private func prepareReview() {
        speech.cancel()
        let draft = DictationParser.parse(inputText, projects: activeProjects)
        // Keep the untouched audio transcription in addition to any manual corrections.
        let raw = (previousRawRecordings + [speech.transcript]).filter { !$0.isEmpty }.joined(separator: "\n")
        originalText = raw.isEmpty ? inputText : raw
        if !raw.isEmpty && raw != inputText {
            originalText += "\n\nTekst prije razvrstavanja:\n" + inputText
        }
        items = draft.items
        if selectedProjectID == nil, draft.projectIsConfident { selectedProjectID = draft.projectID }
        if let detectedID = draft.projectID, let detected = activeProjects.first(where: { $0.id == detectedID }) {
            projectHint = "Prepoznat projekt: \(detected.name). Provjerite odabir prije spremanja."
        } else {
            projectHint = "Projekt nije jednoznačno prepoznat. Ručno odaberite projekt i provjerite odabir."
        }
        if !activeProjects.contains(where: { $0.id == selectedProjectID }) { selectedProjectID = nil }
        saveError = nil
        isReviewing = true
    }

    private func save() {
        guard !isSaving, hasValidItems, let selectedID = selectedProjectID else { return }
        isSaving = true
        defer { isSaving = false }
        let context = modelContext
        // Establish a committed baseline before starting this multi-record edit.
        // If unrelated pending changes cannot be saved, leave them intact.
        do {
            if context.hasChanges { try context.save() }
        } catch {
            saveError = "Prethodne promjene nije moguće spremiti: \(error.localizedDescription). Diktat ostaje dostupan."
            return
        }
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }
        do {
            // Use the displayed main context so project counts and lists update
            // immediately. One save persists all confirmed records together.
            let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == selectedID })
            guard let project = try context.fetch(descriptor).first, !project.isArchived else {
                saveError = "Odabrani projekt više nije dostupan. Odaberite aktivni projekt."
                return
            }
            let source = ProjectNote(text: "Izvorni diktat\n\n" + originalText, sourceTranscript: originalText, project: project)
            context.insert(source)
            for item in items {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch item.category {
                case .note:
                    context.insert(ProjectNote(text: text, sourceTranscript: originalText, project: project))
                case .task:
                    context.insert(ProjectTask(title: String(text.prefix(120)), details: text, project: project))
                case .issue:
                    context.insert(ProjectIssue(title: String(text.prefix(120)), details: text, project: project))
                }
            }
            project.touch()
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            saveError = "Unos nije spremljen: \(error.localizedDescription). Tekst ostaje dostupan za ponovni pokušaj."
        }
    }
}
