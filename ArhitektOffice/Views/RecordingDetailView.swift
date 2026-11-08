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
    @State private var reviewAnalysisContext = false
    @State private var confirmDeleteAudio = false
    @State private var reviewAnalysis: AnalysisResponse?
    @State private var reviewSource: TranscriptVersion?
    @State private var reviewing = false
    @State private var candidateContext: [AIContextRecord] = []
    @State private var selectedContextIDs: Set<UUID> = []
    @State private var selectedProjectIDs: Set<UUID> = []
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var preparingAnalysis = false
    @State private var analysisSource: TranscriptVersion?

    private var isBusy: Bool { processor.isProcessing || preparingAnalysis }
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

    var body: some View {
        Form {
            Section("Snimka") {
                Text(recording.title).font(.headline)
                Text(recording.createdAt, format: .dateTime.day().month().year().hour().minute())
                LabeledContent("Trajanje", value: "\(Int(recording.duration / 60)) min \(Int(recording.duration) % 60) s")
                Picker("Projekt snimke", selection: Binding(get: { recording.project?.id }, set: assignProject)) {
                    Text("Projekt nije odabran").tag(Optional<UUID>.none)
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(isBusy || isActive)
                if let error = recording.lastError { Text(error).foregroundStyle(.orange) }
                if hasAudio {
                    Button(audio.playingSessionID == recording.id ? "Zaustavi reprodukciju" : "Preslušaj snimku",
                           systemImage: audio.playingSessionID == recording.id ? "stop.fill" : "play.fill") {
                        do {
                            if audio.playingSessionID == recording.id { audio.stopPlayback() }
                            else { try audio.play(recording) }
                        } catch { message = error.localizedDescription }
                    }.disabled(isActive || isBusy)
                } else {
                    Text("Zvuk nije dostupan. Transkripti i potvrđena memorija ostaju dostupni.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            transcriptionSection
            if let transcript { transcriptSection(transcript) }
            else {
                Section("Transkript") {
                    Text("Još nema transkripta. Snimku možete obraditi na ovom iPhoneu kasnije ili ručno unijeti tekst.")
                    Button("Ručno unesi cjeloviti transkript") { correcting = true }.disabled(isBusy)
                }
            }
            if hasAudio {
                Section {
                    Button("Obriši lokalni zvučni zapis", role: .destructive) { confirmDeleteAudio = true }
                        .disabled(isActive || isBusy)
                } footer: { Text("Brisanje zvuka ne briše transkripte, izvore ni potvrđenu memoriju.") }
            }
        }
        .navigationTitle("Snimka i transkripti")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Gotovo") { dismiss() }.disabled(isBusy)
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
        .sheet(isPresented: $reviewAnalysisContext) { analysisContextView }
        .sheet(isPresented: $reviewing) {
            if let reviewSource, let reviewAnalysis { MemoryReviewView(transcript: reviewSource, analysis: reviewAnalysis) }
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
        .interactiveDismissDisabled(isBusy)
    }

    private var transcriptionSection: some View {
        Section {
            Button(recording.transcripts.isEmpty ? "Transkribiraj snimku na iPhoneu" : "Nastavi transkripciju iz spremljenih dijelova",
                   systemImage: "text.bubble") { transcribe(force: false) }
                .disabled(!hasAudio || isActive || isBusy)
            if !recording.transcripts.isEmpty || recording.segments.contains(where: { $0.stateRaw.hasSuffix("completed") }) {
                Button("Ponovno transkribiraj sve dijelove", systemImage: "arrow.clockwise") { transcribe(force: true) }
                    .disabled(!hasAudio || isActive || isBusy)
            }
            NavigationLink("Lokalni modeli i mjerenja") { LocalModelsView() }.disabled(isBusy)
            if isBusy {
                if preparingAnalysis {
                    HStack { ProgressView(); Text("Pripremam lokalni kontekst…") }
                } else {
                    ProgressView(value: processor.progress)
                    Text(processor.statusMessage).font(.footnote)
                }
                Button("Prekini obradu", role: .cancel) { operation?.cancel() }
            }
            if let error = processor.errorMessage {
                Text(error).foregroundStyle(.red)
                Text("Izvorni zvuk i prethodni transkripti ostaju sačuvani. Obradu možete ponovno pokrenuti.")
                    .font(.footnote)
            }
        } header: {
            Text("Lokalna obrada na iPhoneu")
        } footer: {
            Text("Transkripcija i analiza izvode se na uređaju pomoću uvezenih modela. Odabrani dijelovi i prethodne verzije ostaju sačuvani nakon prekida; obradu možete nastaviti kasnije.")
        }
    }

    private func transcriptSection(_ version: TranscriptVersion) -> some View {
        Section {
            Picker("Verzija", selection: Binding(get: { transcript?.id }, set: { selectedTranscriptID = $0 })) {
                ForEach(recording.transcripts.reversed()) { value in
                    Text("Verzija \(value.revision) · \(providerLabel(value.provider))").tag(Optional(value.id))
                }
            }.disabled(isBusy)
            Text(version.createdAt, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
            Text(version.text).textSelection(.enabled)
            Button("Ispravi tekst kao novu verziju") { correcting = true }.disabled(isBusy)
            Button("Analiziraj cijeli transkript", systemImage: "sparkles") { prepareAnalysis() }
                .disabled(isBusy || version.text.isEmpty)
            if version.analysisJSON != nil {
                Button("Pregledaj spremljene AI prijedloge") { openSavedAnalysis(version) }.disabled(isBusy)
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

    private var analysisContextView: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Lokalni model analizira odabrani transkript i označene prethodne zapise. Označite projekte koje treba prepoznati. Obrada se izvodi na ovom iPhoneu; prijedloge ćete pregledati prije spremanja.")
                    if let analysisSource { DisclosureGroup("Cjeloviti transkript za analizu") { Text(analysisSource.text).textSelection(.enabled) } }
                }
                Section("Projekti za prepoznavanje · \(selectedProjectIDs.count)/40") {
                    ForEach(projects) { project in
                        Toggle(project.name + (project.number.isEmpty ? "" : " · " + project.number),
                               isOn: selectionBinding(project.id, in: $selectedProjectIDs))
                            .disabled(selectedProjectIDs.count >= 40 && !selectedProjectIDs.contains(project.id))
                    }
                }
                Section("Prethodni lokalni zapisi") {
                    if candidateContext.isEmpty { Text("Nisu odabrani prethodni zapisi.") }
                    ForEach(candidateContext) { record in
                        VStack(alignment: .leading) {
                            Toggle(record.title, isOn: selectionBinding(record.id, in: $selectedContextIDs))
                            Text(record.date, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                            DisclosureGroup("Tekst za lokalni kontekst") { Text(record.text).textSelection(.enabled) }
                        }
                    }
                }
            }
            .navigationTitle("Kontekst lokalne analize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Odustani") { reviewAnalysisContext = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Pokreni analizu") { reviewAnalysisContext = false; analyze() } }
            }
        }
    }

    private func selectionBinding(_ id: UUID, in values: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: {
            if $0 { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }

    private func providerLabel(_ provider: String) -> String {
        if provider == "ručno" { return "Ručni unos" }
        if provider.hasPrefix("whisper-") {
            let suffix = String(provider.dropFirst("whisper-".count))
            let components = suffix.split(separator: "-", maxSplits: 1)
            if let rawKind = components.first, let kind = LocalModelKind(rawValue: String(rawKind)),
               kind == .whisperSmall || kind == .whisperMedium { return kind.title }
            // Historical versions may contain only the model fingerprint.
            return LocalModelStore.shared.manifests.first { suffix.hasSuffix($0.sha256) }?.kind.title ?? "Lokalni Whisper"
        }
        return provider
    }

    private func assignProject(_ id: UUID?) {
        recording.project = projects.first { $0.id == id }
        recording.updatedAt = Date()
        do { try context.save() } catch { context.rollback(); message = error.localizedDescription }
    }
    private func transcribe(force: Bool) {
        guard !isBusy else { return }
        operation = Task { await processor.transcribe(recording: recording, context: context, force: force) }
    }
    private func prepareAnalysis() {
        guard !isBusy, let source = transcript else { return }
        let sourceID = source.id
        let query = source.text
        let projectID = recording.project?.id
        let projectDefaults: Set<UUID>
        if let projectID { projectDefaults = [projectID] }
        else { projectDefaults = Set(projects.filter { !$0.isArchived }.prefix(20).map(\.id)) }
        preparingAnalysis = true
        operation = Task { @MainActor in
            defer { preparingAnalysis = false }
            do {
                let records = try await LocalMemorySearch.recordsAsync(context: context, query: query,
                                                                       projectID: projectID, limit: 12)
                try Task.checkCancellation()
                guard transcript?.id == sourceID else { return }
                candidateContext = records.filter { $0.id != sourceID }
                selectedContextIDs = Set(candidateContext.map(\.id))
                selectedProjectIDs = projectDefaults
                analysisSource = source
                reviewAnalysisContext = true
            } catch is CancellationError {
                message = "Priprema konteksta je prekinuta. Izvorni zapisi ostaju sačuvani."
            } catch { message = error.localizedDescription }
        }
    }

    private func analyze() {
        guard !isBusy, let transcript = analysisSource else { return }
        let chosenProjects = projects.filter { selectedProjectIDs.contains($0.id) }
        let chosenContext = candidateContext.filter { selectedContextIDs.contains($0.id) }
        operation = Task {
            if let result = await processor.analyze(transcript: transcript, projects: chosenProjects,
                                                     context: chosenContext, modelContext: context) {
                reviewSource = transcript; reviewAnalysis = result; reviewing = true
            }
        }
    }
    private func openSavedAnalysis(_ version: TranscriptVersion) {
        do {
            guard let data = version.analysisJSON?.data(using: .utf8) else { return }
            reviewAnalysis = try JSONDecoder().decode(AnalysisResponse.self, from: data)
            reviewSource = version
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
