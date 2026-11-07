import SwiftUI
import SwiftData

@MainActor struct MemoryReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \MemoryEntry.createdAt, order: .reverse) private var memory: [MemoryEntry]
    let transcript: TranscriptVersion
    let summary: String
    @State private var proposals: [MemoryProposal]
    @State private var selected: Set<UUID>
    @State private var message: String?
    @State private var saved = false

    init(transcript: TranscriptVersion, analysis: AnalysisResponse) {
        self.transcript = transcript
        summary = analysis.summary
        var drafts = analysis.proposals
        if !analysis.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !transcript.text.isEmpty, !drafts.contains(where: { $0.kind == .summary }) {
            // A summary is optional and starts unchecked. Its source is the entire
            // retained version; it is never silently promoted into project facts.
            drafts.append(MemoryProposal(id: UUID(), projectID: transcript.recording?.project?.id,
                kind: .summary, certainty: .uncertain,
                title: "Sažetak: " + (transcript.recording?.title ?? "Transkript"), details: analysis.summary,
                responsible: nil, dueDate: nil,
                source: EvidenceReference(transcriptID: transcript.id, startUTF16: 0,
                                          endUTF16: transcript.text.utf16.count, quote: transcript.text),
                relatedEntryID: nil))
        }
        _proposals = State(initialValue: drafts)
        _selected = State(initialValue: Set(analysis.proposals.map(\.id)))
    }

    private var canSave: Bool {
        let chosen = proposals.filter { selected.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy {
            $0.projectID != nil && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("AI nacrt za provjeru") {
                    Text(summary).textSelection(.enabled)
                    Text("Pregledajte vrstu, pouzdanost, osobe, rokove i izvor svakog prijedloga. Podaci se mijenjaju tek nakon vašeg spremanja. Izvorni transkript i raniji zapisi ostaju sačuvani.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if proposals.isEmpty {
                    Section { Text("AI nije predložio strukturirane zapise. Cjeloviti transkript ostaje u memoriji.") }
                }
                ForEach($proposals) { $proposal in
                    Section {
                        Toggle("Spremi ovaj prijedlog", isOn: Binding(
                            get: { selected.contains(proposal.id) },
                            set: { if $0 { selected.insert(proposal.id) } else { selected.remove(proposal.id) } }))
                        proposalFields($proposal)
                            .disabled(!selected.contains(proposal.id))
                        DisclosureGroup("Izvorni navod") {
                            Text(proposal.source.quote).textSelection(.enabled)
                            Text("Transkript v\(transcript.revision) · znakovi \(proposal.source.startUTF16)–\(proposal.source.endUTF16)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Potvrdi informacije")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kasnije", action: saveDraftAndDismiss) }
                ToolbarItem(placement: .confirmationAction) { Button("Spremi odabrano", action: confirm).disabled(!canSave || saved) }
            }
            .alert(saved ? "Memorija je spremljena" : "Spremanje nije uspjelo",
                   isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil; if saved { dismiss() } } })) {
                Button("U redu") { message = nil; if saved { dismiss() } }
            } message: { Text(message ?? "") }
        }
    }

    @ViewBuilder private func proposalFields(_ proposal: Binding<MemoryProposal>) -> some View {
        Picker("Projekt", selection: proposal.projectID) {
            Text("Obvezno odaberite projekt").tag(Optional<UUID>.none)
            ForEach(projects) { project in
                Text(project.name + (project.isArchived ? " · arhiviran" : "")).tag(Optional(project.id))
            }
        }
        Picker("Vrsta", selection: proposal.kind) {
            ForEach(MemoryKind.allCases) { Text($0.label).tag($0) }
        }
        Picker("Pouzdanost", selection: proposal.certainty) {
            ForEach(MemoryCertainty.allCases) { Text($0.label).tag($0) }
        }
        TextField("Naslov", text: proposal.title, axis: .vertical)
        TextField("Cjeloviti detalji", text: proposal.details, axis: .vertical).lineLimit(3...15)
        TextField("Odgovorna osoba (ako je navedena)", text: Binding(
            get: { proposal.wrappedValue.responsible ?? "" },
            set: { proposal.wrappedValue.responsible = $0.isEmpty ? nil : $0 }))
        TextField("Rok: GGGG-MM-DD (ili prazno)", text: Binding(
            get: { proposal.wrappedValue.dueDate ?? "" },
            set: { proposal.wrappedValue.dueDate = $0.isEmpty ? nil : $0 }))
            .keyboardType(.numbersAndPunctuation)
        Picker("Nastavlja prethodni zapis", selection: proposal.relatedEntryID) {
            Text("Samostalan novi zapis").tag(Optional<UUID>.none)
            ForEach(memory.filter { $0.project?.id == proposal.wrappedValue.projectID }) { entry in
                Text(entry.title).tag(Optional(entry.id))
            }
        }
    }

    private func confirm() {
        do {
            let result = try MemoryStore.confirm(proposals: proposals.filter { selected.contains($0.id) },
                                                 transcript: transcript, context: context)
            saved = true
            message = "Dodano zapisa: \(result.insertedCount). Već postojeći zapisi: \(result.skippedCount). Prethodni sadržaj nije zamijenjen."
        } catch { message = error.localizedDescription }
    }

    private func saveDraftAndDismiss() {
        do {
            let data = try JSONEncoder().encode(AnalysisResponse(summary: summary, proposals: proposals))
            transcript.analysisJSON = String(data: data, encoding: .utf8)
            try context.save()
            dismiss()
        } catch { context.rollback(); message = error.localizedDescription }
    }
}
