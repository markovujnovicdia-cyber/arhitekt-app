import SwiftUI
import SwiftData

struct NotesView: View {
    @Query(sort: \ProjectNote.createdAt, order: .reverse) private var notes: [ProjectNote]
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var search = ""
    @State private var projectID: UUID?
    @State private var showEditor = false
    @State private var selectedNote: ProjectNote?

    private var filtered: [ProjectNote] {
        notes.filter { note in
            (projectID == nil || note.project?.id == projectID) &&
            (search.isEmpty || note.text.localizedCaseInsensitiveContains(search) || (note.sourceTranscript?.localizedCaseInsensitiveContains(search) ?? false) || (note.project?.name.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Projekt", selection: $projectID) {
                        Text("Svi projekti").tag(Optional<UUID>.none)
                        ForEach(projects) { Text($0.name + ($0.isArchived ? " · arhiviran" : "")).tag(Optional($0.id)) }
                    }
                }
                if filtered.isEmpty {
                    ContentUnavailableView("Nema bilježaka", systemImage: "note.text", description: Text("Dodajte bilješku ili upotrijebite mikrofon za diktiranje."))
                }
                ForEach(filtered) { note in
                    Button { selectedNote = note } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(note.project?.name ?? "Projekt nije dodijeljen").font(.headline).foregroundStyle(.primary)
                            Text(note.text).foregroundStyle(.primary).lineLimit(5)
                            HStack {
                                Text(note.createdAt, format: .dateTime.day().month().year().hour().minute())
                                if note.sourceTranscript != nil { Image(systemName: "waveform").accessibilityLabel("Sadrži izvorni diktat") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                }
            }
            .navigationTitle("Bilješke")
            .searchable(text: $search, prompt: "Pretraži bilješke i izvorne diktate")
            .toolbar { Button { showEditor = true } label: { Label("Nova bilješka", systemImage: "plus") } }
            .sheet(isPresented: $showEditor) { NoteEditor() }
            .sheet(item: $selectedNote) { NoteEditor(note: $0) }
        }
    }
}
