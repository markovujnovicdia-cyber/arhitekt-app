import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let arhitektOfficeBackup = UTType(exportedAs: "com.arhitektoffice.backup", conformingTo: .package)
}

struct PortableBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.arhitektOfficeBackup] }
    var package: FileWrapper
    init(package: FileWrapper) { self.package = package }
    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isDirectory else { throw CocoaError(.fileReadCorruptFile) }
        package = configuration.file
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { package }
}

@MainActor
struct PortableBackupView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var recording = LongRecordingService.shared
    @State private var document = PortableBackupDocument(package: FileWrapper(directoryWithFileWrappers: [:]))
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var confirmImport = false
    @State private var selectedURL: URL?
    @State private var message: String?
    @State private var busy = false
    @State private var importTask: Task<Void, Never>?

    private var recordingActive: Bool {
        recording.state == .recording || recording.state == .paused || recording.state == .preparing
    }

    var body: some View {
        Form {
            Section("Cjelovita kopija s audio snimkama") {
                Text("Paket .officebackup sadrži uredske podatke, sve revizije transkripata, memoriju projekata, izvorni CAF zvuk, dijelove za obradu i dnevnike oporavka. API ključevi i postavke cloud pristupa nisu uključeni.")
                Button("Izvezi paket s audio snimkama", systemImage: "externaldrive.badge.plus") { exportPackage() }
                    .frame(minHeight: 44)
                    .disabled(busy || recordingActive)
                Button("Uvezi paket s audio snimkama", systemImage: "square.and.arrow.down") { showImporter = true }
                    .frame(minHeight: 44)
                    .disabled(busy || recordingActive)
                if busy { ProgressView("Provjera i kopiranje podataka…") }
                if recordingActive {
                    Label("Najprije završite aktivno ili pauzirano snimanje.", systemImage: "mic.slash")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Sigurna obnova") {
                Text("Prije uvoza izvezite trenutačno stanje. JSON se provjerava u odvojenoj privremenoj bazi prije kopiranja zvuka. Novi zapisi se dodaju; uredski zapisi s istim identifikatorom obnavljaju se prema pravilima JSON uvoza.")
                Text("Izvorne audio datoteke nikad se ne prepisuju. Ako ista putanja već sadrži drukčiji zvuk ili dnevnik, uvoz se odbija. Jednake datoteke mogu se ponovno uvesti bez duplikata. Transkripti i postojeća memorija čuvaju se kao povijesni zapisi.")
                Text("Paket je mapa koju Datoteke prikazuju kao dokument. Prenesite ga cijelog, primjerice preko iCloud Drivea ili AirDropa. Za dijeljenje e-poštom najprije ga komprimirajte u aplikaciji Datoteke i raspakirajte prije uvoza.")
            }
            Section("Prostor i privatnost") {
                Text("Najviše 2 GB zvuka i 20 MB JSON metapodataka po paketu. Za uvoz je potreban prostor za privremenu i završnu kopiju novih snimaka. Ne prekidajte aplikaciju tijekom uvoza ili izvoza.")
                Text("Paket nije šifriran i sadrži potpune snimke razgovora. Spremite ga na pouzdanu lokaciju. Prijenos preko odabranog servisa u Datotekama slijedi vašu izričitu odluku.")
                Text("Ako se aplikacija neočekivano zatvori između kopiranja i spremanja baze, zvuk može ostati kao oporavljiva snimka. Ponovite uvoz istog paketa; postojeći jednaki zvuk ostaje sačuvan.")
            }
        }
        .navigationTitle("Kopija s audio zapisima")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showExporter, document: document, contentType: .arhitektOfficeBackup,
                      defaultFilename: "Arhitekt-Office-potpuna-kopija") { result in
            switch result {
            case .success: message = "Cjelovita sigurnosna kopija je izvezena."
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { message = "Izvoz nije uspio: \(error.localizedDescription)" }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.arhitektOfficeBackup]) { result in
            switch result {
            case .success(let url): selectedURL = url; confirmImport = true
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { message = "Paket nije moguće otvoriti: \(error.localizedDescription)" }
            }
        }
        .confirmationDialog("Obnoviti podatke iz paketa?", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Provjeri i uvezi paket") { importPackage() }
            Button("Odustani", role: .cancel) { selectedURL = nil }
        } message: {
            Text("Jeste li izvezli aktualno stanje? Uredski zapisi s istim identifikatorom mogu se obnoviti iz starije kopije. Audio datoteke se ne prepisuju; sukob prekida uvoz.")
        }
        .alert("Sigurnosna kopija", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("U redu", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .interactiveDismissDisabled(busy)
        .navigationBarBackButtonHidden(busy)
        .onDisappear { importTask?.cancel() }
    }

    private func exportPackage() {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try context.save()
            document = PortableBackupDocument(package: try PortableBackupService.export(context: context))
            showExporter = true
        } catch { message = "Paket nije pripremljen: \(error.localizedDescription)" }
    }

    private func importPackage() {
        guard !busy, let url = selectedURL else { return }
        selectedURL = nil
        busy = true
        importTask = Task { @MainActor in
            defer { busy = false }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await PortableBackupService.importPackage(at: url, into: context)
                message = "Paket je uvezen: \(result.projectCount) projekata i \(result.itemCount) povezanih zapisa."
            } catch is CancellationError {
                message = "Uvoz je otkazan; postojeći podaci ostaju sačuvani."
            } catch { message = "Uvoz nije uspio: \(error.localizedDescription)" }
        }
    }
}
