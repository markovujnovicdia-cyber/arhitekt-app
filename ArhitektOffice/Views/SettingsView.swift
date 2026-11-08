import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var document = BackupFileDocument(data: Data())
    @State private var exporting = false
    @State private var importing = false
    @State private var pendingImport: Data?
    @State private var confirmImport = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("AI i potpune kopije") {
                    NavigationLink("Lokalni AI modeli i izvođenje") { LocalModelsView() }
                    NavigationLink("Mjerenja lokalnog izvođenja") { LocalRuntimeView() }
                    NavigationLink("Kopija podataka i audio snimki") { PortableBackupView() }
                }
                Section("JSON podaci bez zvuka") {
                    Button("Izvezi podatke u JSON", systemImage: "square.and.arrow.up") { exportBackup() }
                        .frame(minHeight: 44)
                    Button("Uvezi podatke iz JSON-a", systemImage: "square.and.arrow.down") { importing = true }
                        .frame(minHeight: 44)
                    Text("JSON obuhvaća podatke i transkripte, ali ne i zvučne datoteke. Za prenosivu kopiju sa zvukom odaberite Kopija podataka i audio snimki.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Uvoz dodaje nove zapise i obnavlja zapise s istim identifikatorom iz kopije. Ostali zapisi se ne brišu. Prije uvoza izvezite trenutačne podatke.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Privatnost i pohrana") {
                    Label("Podaci se čuvaju lokalno na iPhoneu", systemImage: "iphone")
                    Text("Snimanje, transkripcija, analiza i odgovori koriste isključivo lokalnu pohranu i modele na iPhoneu. Aplikacija ne traži mrežni poslužitelj, registraciju ni API ključ.")
                    Text("Modele uvezite iz aplikacije Datoteke. Aplikacija ih ne preuzima. Za lokalno izvođenje razvojna verzija mora sadržavati Whisper i llama.cpp biblioteke; postupak je opisan u uputama projekta. Brisanje aplikacije uklanja lokalne podatke i modele, stoga prethodno izvezite potpunu kopiju.")
                }
                Section("Arhitekt Office") {
                    LabeledContent("Verzija", value: "2.0 · lokalno")
                    Text("Osobni ured za arhitektonske projekte.")
                }
            }
            .navigationTitle("Postavke")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Gotovo") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                          defaultFilename: "Arhitekt-Office-sigurnosna-kopija") { result in
                switch result {
                case .success: message = "Sigurnosna kopija je izvezena."
                case .failure(let error): message = "Izvoz nije uspio: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= BackupService.maximumBytes else {
                        message = "Datoteka je prevelika (najviše 20 MB)."; return
                    }
                    pendingImport = try Data(contentsOf: url, options: .mappedIfSafe)
                    confirmImport = true
                } catch { message = "Datoteku nije moguće pročitati: \(error.localizedDescription)" }
            }
            .confirmationDialog("Uvesti sigurnosnu kopiju?", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("Uvezi podatke") { importBackup() }
                Button("Odustani", role: .cancel) { pendingImport = nil }
            } message: {
                Text("Zapisi s istim identifikatorom bit će zamijenjeni podacima iz kopije. Ostali zapisi se ne brišu. Jeste li izvezli trenutačne podatke?")
            }
            .alert("Sigurnosna kopija", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("U redu", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
        }
    }

    private func exportBackup() {
        do {
            try context.save()
            document = BackupFileDocument(data: try BackupService.export(context: context))
            exporting = true
        } catch { message = "Izvoz nije uspio: \(error.localizedDescription)" }
    }

    private func importBackup() {
        guard let data = pendingImport else { return }
        pendingImport = nil
        do {
            let result = try BackupService.importData(data, into: context)
            message = "Uvoz je dovršen: \(result.projectCount) projekata i \(result.itemCount) povezanih zapisa."
        } catch { message = "Uvoz nije uspio: \(error.localizedDescription)" }
    }
}
