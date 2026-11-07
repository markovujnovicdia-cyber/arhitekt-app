import SwiftUI
import SwiftData

@MainActor struct RecordingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]
    @Bindable var recording: RecordingSession
    var showsCloseButton = false
    @StateObject private var processor = RecordingProcessingService()
    @ObservedObject private var audio = LongRecordingService.shared
    @State private var selectedTranscriptID: UUID?
    @State private var correcting = false
    @State private var consentTranscription = false
    @State private var consentAnalysis = false
    @State private var confirmDeleteAudio = false
    @State private var reviewAnalysis: AnalysisResponse?
    @State private var reviewing = false
    @State private var candidateContext: [AIContextRecord] = []
    @State private var selectedContextIDs: Set<UUID> = []
    @State private var selectedProjectIDs: Set<UUID> = []
    @State private var message: String?
    @State private var operation: Task<Void, Never>?

    private var transcript: TranscriptVersion? {
        recording.transcripts.first { $0.id == selectedTranscriptID } ?? recording.transcripts.last
    }
    private var isActive: Bool {
        ["recording", "paused", "preparing", "interrupted"].contains(recording.stateRaw) ||
        (audio.currentSession?.id == recording.id && (audio.state == .recording || audio.state == .paused || audio.state == .preparing))
    }
    private var hasAudio: Bool {
        recording.stateRaw != "audioDeleted" &&
        (recording.masterRelativePath != nil || recording.segments.contains { $0.stateRaw != "audioDeleted" })
    }
    private var backendName: String { AIConfiguration.baseURL?.host ?? "AI poslužitelj iz Postavki" }

    var body: some View {
        Form {
            Section("Snimka") {
                Text(recording.title).font(.headline)
                Text(recording.createdAt, format: .dateTime.day().month().year().hour().minute())
                LabeledContent("Trajanje", value: "\(Int(recording.duration / 60)) min \(Int(recording.duration) % 60) s")
                Picker("Projekt snimke", selection: Binding(get: { recording.project?.id }, set: assignProject)) {
                    Text("Projekt nije odabran").tag(Optional<UUID>.none)
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(processor.isProcessing || isActive)
                if let error = recording.lastError { Text(error).foregroundStyle(.orange) }
                if hasAudio {
                    Button(audio.playingSessionID == recording.id ? "Zaustavi reprodukciju" : "Preslušaj snimku",
                           systemImage: audio.playingSessionID == recording.id ? "stop.fill" : "play.fill") {
                        do {
                            if audio.playingSessionID == recording.id { audio.stopPlayback() }
                            else { try audio.play(recording) }
                        } catch { message = error.localizedDescription }
                    }.disabled(isActive)
                } else {
                    Text("Zvuk nije dostupan. Transkripti i potvrđena memorija ostaju dostupni.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            transcriptionSection
            if let transcript { transcriptSection(transcript) }
            else {
                Section("Transkript") {
                    Text("Još nema transkripta. Snimku možete poslati na obradu kasnije ili ručno unijeti tekst.")
                    Button("Ručno unesi cjeloviti transkript") { correcting = true }
                }
            }
            if hasAudio {
                Section {
                    Button("Obriši lokalni zvučni zapis", role: .destructive) { confirmDeleteAudio = true }
                        .disabled(isActive || processor.isProcessing)
                } footer: { Text("Brisanje zvuka ne briše transkripte, izvore ni potvrđenu memoriju.") }
            }
        }
        .navigationTitle("Snimka i transkripti")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Gotovo") { dismiss() }.disabled(processor.isProcessing)
                }
            }
        }
        .onAppear { selectedTranscriptID = recording.transcripts.last?.id }
        .onDisappear {
            operation?.cancel()
            if audio.playingSessionID == recording.id { audio.stopPlayback() }
        }
        .onChange(of: recording.transcripts.count) { _, _ in selectedTranscriptID = recording.transcripts.last?.id }
        .sheet(isPresented: $correcting) {
            TranscriptCorrectionView(recording: recording, initialText: transcript?.text ?? "")
        }
        .sheet(isPresented: $consentAnalysis) { analysisConsentView }
        .sheet(isPresented: $reviewing) {
            if let transcript, let reviewAnalysis { MemoryReviewView(transcript: transcript, analysis: reviewAnalysis) }
        }
        .confirmationDialog("Poslati zvuk na transkripciju?", isPresented: $consentTranscription, titleVisibility: .visible) {
            Button("Dopuštam slanje zvuka") { transcribe() }
            Button("Odustani", role: .cancel) {}
        } message: {
            Text("Snimka „\(recording.title)” (\(Int(recording.duration / 60)) min) bit će obrađena u poredanim dijelovima putem \(backendName) i njegova pružatelja transkripcije. Poslat će se zvuk ove snimke. Neuspjeh ne briše zvuk ni prethodne verzije transkripta.")
        }
        .confirmationDialog("Trajno obrisati lokalni zvuk?", isPresented: $confirmDeleteAudio, titleVisibility: .visible) {
            Button("Obriši zvuk", role: .destructive) {
                do { try audio.deleteAudio(for: recording, context: context) }
                catch { message = error.localizedDescription }
            }
            Button("Odustani", role: .cancel) {}
        } message: { Text("Ova se radnja ne može poništiti. Svi transkripti i zapisi ostaju sačuvani.") }
        .alert("Arhitekt Office", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("U redu") { message = nil }
        } message: { Text(message ?? "") }
        .interactiveDismissDisabled(processor.isProcessing)
    }

    private var transcriptionSection: some View {
        Section {
            Button(recording.transcripts.isEmpty ? "Transkribiraj spremljenu snimku" : "Ponovno obradi zvučni zapis",
                   systemImage: "text.bubble") { consentTranscription = true }
                .disabled(!hasAudio || isActive || processor.isProcessing)
            if processor.isProcessing {
                ProgressView(value: processor.progress)
                Text(processor.statusMessage).font(.footnote)
                Button("Prekini obradu", role: .cancel) { operation?.cancel() }
            }
            if let error = processor.errorMessage {
                Text(error).foregroundStyle(.red)
                Text("Izvorni zvuk i prethodni transkripti ostaju sačuvani. Obradu možete ponovno pokrenuti.")
                    .font(.footnote)
            }
        } header: {
            Text("Cloud obrada uz privolu")
        } footer: {
            Text("Snimanje i čuvanje rade bez interneta. Transkripcija i AI analiza zahtijevaju podešen poslužitelj i mrežu.")
        }
    }

    private func transcriptSection(_ version: TranscriptVersion) -> some View {
        Section {
            Picker("Verzija", selection: Binding(get: { transcript?.id }, set: { selectedTranscriptID = $0 })) {
                ForEach(recording.transcripts.reversed()) { value in
                    Text("Verzija \(value.revision) · \(value.provider)").tag(Optional(value.id))
                }
            }.disabled(processor.isProcessing)
            Text(version.createdAt, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
            Text(version.text).textSelection(.enabled)
            Button("Ispravi tekst kao novu verziju") { correcting = true }.disabled(processor.isProcessing)
            Button("Analiziraj cijeli transkript", systemImage: "sparkles") { prepareAnalysis() }
                .disabled(processor.isProcessing || version.text.isEmpty)
            if version.analysisJSON != nil {
                Button("Pregledaj spremljene AI prijedloge") { openSavedAnalysis(version) }.disabled(processor.isProcessing)
            }
            if let summary = version.analysisSummary {
                DisclosureGroup("AI sažetak za provjeru") { Text(summary).textSelection(.enabled) }
            }
            Text("Potvrđenih informacija iz ove verzije: \(version.memory.count)").font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Cjeloviti transkript")
        } footer: {
            Text("Ispravci i ponovna transkripcija stvaraju novu verziju. Raniji tekst ostaje dostupan i citati se nastavljaju odnositi na izvornu verziju.")
        }
    }

    private var analysisConsentView: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Slanjem dopuštate obradu putem \(backendName) i njegova AI pružatelja. Poslat će se cjeloviti odabrani transkript, nazivi i brojevi označenih projekata te samo označeni prethodni zapisi.")
                    if let transcript { DisclosureGroup("Cjeloviti transkript koji se šalje") { Text(transcript.text).textSelection(.enabled) } }
                }
                Section("Projekti za prepoznavanje") {
                    ForEach(projects) { project in
                        Toggle(project.name + (project.number.isEmpty ? "" : " · " + project.number),
                               isOn: selectionBinding(project.id, in: $selectedProjectIDs))
                    }
                }
                Section("Prethodni lokalni zapisi") {
                    if candidateContext.isEmpty { Text("Nisu odabrani prethodni zapisi.") }
                    ForEach(candidateContext) { record in
                        VStack(alignment: .leading) {
                            Toggle(record.title, isOn: selectionBinding(record.id, in: $selectedContextIDs))
                            Text(record.date, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                            DisclosureGroup("Točan tekst koji se šalje") { Text(record.text).textSelection(.enabled) }
                        }
                    }
                }
            }
            .navigationTitle("Pregled slanja AI-ju")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Odustani") { consentAnalysis = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Dopuštam i šaljem") { consentAnalysis = false; analyze() } }
            }
        }
    }

    private func selectionBinding(_ id: UUID, in values: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: {
            if $0 { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }

    private func assignProject(_ id: UUID?) {
        recording.project = projects.first { $0.id == id }
        recording.updatedAt = Date()
        do { try context.save() } catch { context.rollback(); message = error.localizedDescription }
    }
    private func transcribe() {
        let force = !recording.transcripts.isEmpty
        operation = Task { await processor.transcribe(recording: recording, context: context, force: force) }
    }
    private func prepareAnalysis() {
        guard let transcript else { return }
        do {
            candidateContext = try LocalMemorySearch.records(context: context, query: transcript.text,
                                                              projectID: recording.project?.id, limit: 12)
                .filter { $0.id != transcript.id }
            selectedContextIDs = Set(candidateContext.map(\.id))
            selectedProjectIDs = Set(projects.filter { !$0.isArchived || $0.id == recording.project?.id }.map(\.id))
            consentAnalysis = true
        } catch { message = error.localizedDescription }
    }
    private func analyze() {
        guard let transcript else { return }
        let chosenProjects = projects.filter { selectedProjectIDs.contains($0.id) }
        let chosenContext = candidateContext.filter { selectedContextIDs.contains($0.id) }
        operation = Task {
            if let result = await processor.analyze(transcript: transcript, projects: chosenProjects,
                                                     context: chosenContext, modelContext: context) {
                reviewAnalysis = result; reviewing = true
            }
        }
    }
    private func openSavedAnalysis(_ version: TranscriptVersion) {
        do {
            guard let data = version.analysisJSON?.data(using: .utf8) else { return }
            reviewAnalysis = try JSONDecoder().decode(AnalysisResponse.self, from: data)
            reviewing = true
        } catch { message = "AI nacrt nije moguće pročitati. Izvorni transkript ostaje dostupan. " + error.localizedDescription }
    }
}

@MainActor private struct TranscriptCorrectionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let recording: RecordingSession
    @State private var text: String
    @State private var message: String?
    init(recording: RecordingSession, initialText: String) {
        self.recording = recording; _text = State(initialValue: initialText)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 350).accessibilityLabel("Cjeloviti ispravljeni transkript")
                } footer: { Text("Spremanje stvara novu verziju. Stari tekst i njegove reference ostaju nepromijenjeni.") }
            }
            .navigationTitle("Nova verzija transkripta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Odustani") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spremi") {
                        do { _ = try MemoryStore.appendTranscript(text: text, to: recording, provider: "ručno", context: context); dismiss() }
                        catch { message = error.localizedDescription }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Spremanje nije uspjelo", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("U redu") { message = nil }
            } message: { Text(message ?? "") }
            .interactiveDismissDisabled(!text.isEmpty)
        }
    }
}
