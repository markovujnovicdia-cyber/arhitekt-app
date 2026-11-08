import SwiftUI
import SwiftData

private struct OfficeAnswerTurn: Identifiable {
    let id = UUID()
    let question: String
    let answer: AskResponse
    let sources: [AIContextRecord]
    let date = Date()
}

@MainActor struct AskOfficeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var question = ""
    @State private var projectID: UUID?
    @State private var retrievedQuestion = ""
    @State private var retrievedProjectID: UUID?
    @State private var candidates: [AIContextRecord] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var turns: [OfficeAnswerTurn] = []
    @State private var source: AIContextRecord?
    @State private var isAsking = false
    @State private var isRetrieving = false
    @State private var message: String?
    @State private var requestTask: Task<Void, Never>?

    private var isWorking: Bool { isAsking || isRetrieving }
    private var trimmedQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var retrievalCurrent: Bool { retrievedQuestion == trimmedQuestion && retrievedProjectID == projectID }
    private var selectedContext: [AIContextRecord] { candidates.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Form {
                questionSection
                contextSection
                if isWorking {
                    Section {
                        HStack { ProgressView(); Text(isRetrieving ? "Pretražujem lokalnu memoriju…" : "Tražim odgovor u odabranim izvorima…") }
                        Button(isRetrieving ? "Prekini pretraživanje" : "Zaustavi lokalni odgovor", role: .cancel) { requestTask?.cancel() }
                    }
                }
                if let message {
                    Section("Obavijest") { Text(message).foregroundStyle(.secondary) }
                }
                ForEach(turns.reversed()) { turn in
                    Section {
                        Text(turn.question).font(.headline)
                        Text(turn.date, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        if turn.answer.insufficientData {
                            Label("Nema dovoljno podataka za pouzdan odgovor", systemImage: "questionmark.circle")
                                .foregroundStyle(.orange)
                        }
                        Text(turn.answer.answer).textSelection(.enabled)
                        ForEach(turn.sources) { record in
                            Button { source = record } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(record.title, systemImage: "doc.text.magnifyingglass")
                                    Text(record.date, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                                }
                            }
                        }
                    } header: { Text("Odgovor i izvori") }
                }
            }
            .navigationTitle("Pitaj Arhitekt Office")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { requestTask?.cancel() }
            .sheet(item: $source) { record in
                NavigationStack {
                    SourceRecordView(record: record)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Gotovo") { source = nil } } }
                }
            }
        }
    }

    private var questionSection: some View {
        Section {
            TextField("Primjer: Što smo posljednje dogovorili oko garaže?", text: $question, axis: .vertical)
                .lineLimit(3...8).disabled(isWorking)
            Picker("Opseg", selection: $projectID) {
                Text("Svi projekti, uključujući arhivu").tag(Optional<UUID>.none)
                ForEach(projects) { project in
                    Text(project.name + (project.isArchived ? " · arhiviran" : "")).tag(Optional(project.id))
                }
            }.disabled(isWorking)
            Button("Pronađi relevantne lokalne zapise", systemImage: "magnifyingglass", action: retrieve)
                .disabled(trimmedQuestion.isEmpty || isWorking)
            NavigationLink("Lokalni model i mjerenja") { LocalModelsView() }.disabled(isWorking)
        } header: {
            Text("Pitanje")
        } footer: {
            Text("Pretraživanje i AI odgovor izvode se na ovom iPhoneu. Odgovor je lokalni AI nacrt koji može pogrešno protumačiti podatke; provjerite citirane izvore. Ako nema dovoljno izvora, aplikacija će to jasno reći. Potreban je uvezen lokalni jezični model.")
        }
    }

    @ViewBuilder private var contextSection: some View {
        if !candidates.isEmpty {
            Section {
                ForEach(candidates) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(record.title, isOn: Binding(get: { selectedIDs.contains(record.id) }, set: {
                            if $0 { selectedIDs.insert(record.id) } else { selectedIDs.remove(record.id) }
                        })).disabled(isWorking)
                        Text(record.date, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Tekst za lokalni kontekst") { Text(record.text).textSelection(.enabled) }
                    }
                }
                if !retrievalCurrent {
                    Text("Pitanje ili projekt su promijenjeni. Ponovno pronađite relevantne zapise prije analize.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button("Odgovori lokalno iz odabranih zapisa", systemImage: "brain.head.profile", action: ask)
                    .disabled(isWorking || selectedContext.isEmpty || !retrievalCurrent)
            } header: { Text("Pregled konteksta · \(selectedContext.count) odabrano") }
        }
    }

    private func retrieve() {
        guard !isWorking, !trimmedQuestion.isEmpty else { return }
        let query = trimmedQuestion
        let selectedProject = projectID
        isRetrieving = true
        message = nil
        requestTask = Task { @MainActor in
            defer { isRetrieving = false }
            do {
                let records = try await LocalMemorySearch.recordsAsync(context: context, query: query,
                                                                       projectID: selectedProject, limit: 20)
                try Task.checkCancellation()
                candidates = records
                selectedIDs = Set(records.map(\.id))
                retrievedQuestion = query
                retrievedProjectID = selectedProject
                if records.isEmpty {
                    turns.append(OfficeAnswerTurn(question: query,
                        answer: AskResponse(answer: "U lokalnoj bazi nisam pronašao dovoljno relevantnih podataka. Pokušajte navesti naziv projekta ili druge riječi, odnosno prvo dodajte snimku ili bilješku.",
                                            sourceIDs: [], insufficientData: true), sources: []))
                }
            } catch is CancellationError {
                message = "Pretraživanje je prekinuto. Projektni podaci ostaju sačuvani."
            } catch { message = error.localizedDescription }
        }
    }

    private func ask() {
        guard retrievalCurrent, !selectedContext.isEmpty, !isWorking else { return }
        let askedQuestion = trimmedQuestion
        let usedContext = selectedContext
        isAsking = true; message = nil
        requestTask = Task { @MainActor in
            defer { isAsking = false }
            do {
                let result = try await LocalAIClient().ask(question: askedQuestion, context: usedContext)
                turns.append(OfficeAnswerTurn(question: askedQuestion, answer: result,
                    sources: usedContext.filter { result.sourceIDs.contains($0.id) }))
            } catch is CancellationError {
                message = "Lokalna obrada je prekinuta. Projektni podaci ostaju sačuvani."
            } catch { message = error.localizedDescription }
        }
    }
}

/// Displays the exact source snapshot used by a grounded answer, with a route
/// to the retained original model when it still exists in the local database.
struct SourceRecordView: View {
    let record: AIContextRecord
    @Query private var notes: [ProjectNote]
    @Query private var transcripts: [TranscriptVersion]
    @Query private var entries: [MemoryEntry]
    @Query private var tasks: [ProjectTask]
    @Query private var issues: [ProjectIssue]
    var body: some View {
        Form {
            Section("Citirani izvor") {
                Text(record.title).font(.headline)
                Text(record.date, format: .dateTime.day().month().year().hour().minute()).foregroundStyle(.secondary)
                Text(record.text).textSelection(.enabled)
            }
            if record.recordType == "note", let note = notes.first(where: { $0.id == record.id }) {
                Section { NavigationLink("Otvori izvornu bilješku") { NoteMemoryDetailView(note: note) } }
            }
            if record.recordType == "memory", let entry = entries.first(where: { $0.id == record.id }) {
                Section { NavigationLink("Otvori informaciju i dokaz") { MemoryEntryDetailView(entry: entry) } }
            }
            if record.recordType == "transcript", let transcript = transcripts.first(where: { $0.id == record.id }) {
                Section("Izvorna verzija transkripta") {
                    Text("Verzija \(transcript.revision) · \(transcript.provider)").font(.caption)
                    DisclosureGroup("Cjeloviti tekst") { Text(transcript.text).textSelection(.enabled) }
                    if let recording = transcript.recording {
                        NavigationLink("Otvori snimku i sve verzije") { RecordingDetailView(recording: recording) }
                    }
                }
            }
            if record.recordType == "task", let task = tasks.first(where: { $0.id == record.id }) {
                Section { NavigationLink("Otvori izvorni zadatak") { LegacyMemoryDetailView(task: task) } }
            }
            if record.recordType == "issue", let issue = issues.first(where: { $0.id == record.id }) {
                Section { NavigationLink("Otvori izvorni problem") { LegacyMemoryDetailView(issue: issue) } }
            }
        }
        .navigationTitle("Izvor odgovora")
        .navigationBarTitleDisplayMode(.inline)
    }
}
