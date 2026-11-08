import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LocalModelsView: View {
    @ObservedObject private var models = LocalModelStore.shared
    @ObservedObject private var runtime = LocalRuntimeMonitor.shared
    @State private var importKind = LocalModelKind.whisperSmall
    @State private var expectedChecksum = ""
    @State private var choosingFile = false
    @State private var pendingRemoval: LocalModelKind?
    @State private var importTask: Task<Void, Never>?
    @State private var message: String?

    private var normalizedChecksum: String { expectedChecksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var validChecksum: Bool {
        normalizedChecksum.isEmpty || (normalizedChecksum.count == 64 && normalizedChecksum.allSatisfy { $0.isHexDigit && $0.isASCII })
    }

    var body: some View {
        Form {
            Section("Obrada na ovom iPhoneu") {
                Label("Obrada na iPhoneu", systemImage: "iphone")
                Text("Zvuk, transkripti i projektni kontekst obrađuju se na uređaju. Modeli nisu uključeni u veličinu aplikacije. Uvezite pripremljene datoteke iz aplikacije Datoteke.")
                Text("Za izvođenje razvojna verzija mora sadržavati lokalne Whisper i llama.cpp biblioteke. Ako izvođač nedostaje, pratite upute za izgradnju biblioteka na Macu uz izvorni projekt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Odabir modela za govor") {
                Picker("Whisper", selection: $models.selectedWhisperKind) {
                    Text(LocalModelKind.whisperSmall.title).tag(LocalModelKind.whisperSmall)
                    Text(LocalModelKind.whisperMedium.title).tag(LocalModelKind.whisperMedium)
                }.disabled(models.isImporting || runtime.activeName != nil)
                Text("Small je početni izbor za iPhone 16 Pro. Medium zahtijeva više memorije i dulju obradu. Za hrvatski govor koristite višejezične modele, bez nastavka .en.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Uvoz modela iz Datoteka") {
                Picker("Datoteka za model", selection: $importKind) {
                    ForEach(LocalModelKind.allCases) { Text($0.title).tag($0) }
                }.disabled(models.isImporting || runtime.activeName != nil)
                Text(importKind.detail).font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Očekivana datoteka", value: importKind.suggestedFilename)
                TextField("SHA-256 iz pouzdanog izvora (neobvezno)", text: $expectedChecksum, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.asciiCapable).font(.system(.caption, design: .monospaced))
                    .disabled(models.isImporting)
                if !validChecksum {
                    Text("SHA-256 mora sadržavati 64 heksadecimalna znaka ili ostati prazan.").font(.footnote).foregroundStyle(.red)
                }
                Text("Ako unesete očekivani SHA-256, uvoz uspoređuje izračunati otisak s tom vrijednošću. Izračunati otisak bez očekivane vrijednosti služi evidenciji; format i veličina datoteke provjeravaju se zasebno.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Odaberi lokalnu datoteku", systemImage: "folder") { choosingFile = true }
                    .disabled(models.isImporting || runtime.activeName != nil || !validChecksum)
                if models.isImporting {
                    ProgressView(value: models.progress)
                    Text("Kopiranje i provjera modela…").font(.footnote)
                    Button("Prekini uvoz", role: .cancel) { importTask?.cancel() }
                }
                if let error = models.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            ForEach(LocalModelKind.allCases) { kind in
                Section(kind.title) {
                    if let manifest = models.manifest(for: kind) {
                        Label("Datoteka je uvezena", systemImage: "checkmark.circle").foregroundStyle(.green)
                        Text(manifest.checksumVerifiedAgainstExpected ? "Provjereno prema očekivanom SHA-256." : "Otisak je evidentiran bez očekivane kontrolne vrijednosti.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Datoteka", value: manifest.fileName)
                        LabeledContent("Veličina", value: ByteCountFormatter.string(fromByteCount: manifest.byteCount, countStyle: .file))
                        LabeledContent("Format", value: manifest.format)
                        LabeledContent("Arhitektura", value: manifest.architecture)
                        LabeledContent("Kvantizacija", value: manifest.quantization)
                        LabeledContent("Uvezeno") { Text(manifest.importedAt, format: .dateTime.day().month().year().hour().minute()) }
                        DisclosureGroup("SHA-256 datoteke") {
                            Text(manifest.sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        Button("Ukloni ovu datoteku modela", role: .destructive) { pendingRemoval = kind }
                            .disabled(models.isImporting || runtime.activeName != nil)
                    } else {
                        Label("Model nije uvezen", systemImage: "externaldrive.badge.questionmark")
                        Text(kind.suggestedFilename).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Mjerenje na uređaju") {
                NavigationLink("Izvođenje i posljednja mjerenja") { LocalRuntimeView() }
            }
        }
        .navigationTitle("Lokalni AI modeli")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data, .item]) { result in
            do {
                let url = try result.get()
                let kind = importKind
                let checksum = normalizedChecksum.isEmpty ? nil : normalizedChecksum
                importTask = Task { @MainActor in
                    do {
                        try await models.importModel(from: url, kind: kind, expectedSHA256: checksum)
                        message = "Datoteka modela je uvezena i provjerena."
                    } catch is CancellationError {
                        message = "Uvoz je prekinut. Ponovno odaberite datoteku kada želite nastaviti."
                    } catch { message = error.localizedDescription }
                }
            } catch { message = error.localizedDescription }
        }
        .confirmationDialog("Ukloniti datoteku modela?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Ukloni model", role: .destructive) {
                guard let kind = pendingRemoval else { return }
                do { try models.remove(kind) }
                catch { message = error.localizedDescription }
                pendingRemoval = nil
            }
            Button("Odustani", role: .cancel) { pendingRemoval = nil }
        } message: { Text("Snimke, transkripti i projektni podaci ostaju sačuvani. Za novu obradu ponovno uvezite model.") }
        .alert("Lokalni modeli", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("U redu") { message = nil }
        } message: { Text(message ?? "") }
        .interactiveDismissDisabled(models.isImporting)
    }
}

@MainActor
struct LocalRuntimeView: View {
    @ObservedObject private var monitor = LocalRuntimeMonitor.shared
    var body: some View {
        List {
            Section {
                Text("Mjerenja se popunjavaju nakon stvarne lokalne obrade. Brzina ovisi o modelu, duljini ulaza, slobodnoj memoriji i zagrijavanju iPhonea.")
                LabeledContent("Trenutačno toplinsko stanje", value: monitor.thermalState)
                Text("Toplinsko stanje potječe od iOS-a. Sustav ne daje temperaturu procesora u °C.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let activeName = monitor.activeName {
                Section("Obrada u tijeku") { HStack { ProgressView(); Text(modelLabel(activeName)) } }
            }
            if monitor.memoryWarningCount > 0 {
                Section("Memorijski pritisak") {
                    Text("Broj upozorenja sustava: \(monitor.memoryWarningCount)")
                    Text("Veći model možete zamijeniti modelom Small. Nedovršena obrada čuva dostupne rezultate za nastavak.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if monitor.reports.isEmpty {
                ContentUnavailableView("Još nema mjerenja", systemImage: "gauge.with.dots.needle.33percent",
                    description: Text("Pokrenite lokalnu transkripciju, analizu ili odgovor. Ovdje se ne prikazuju procijenjeni rezultati."))
            }
            ForEach(monitor.reports) { report in
                Section(modelLabel(report.modelName)) {
                    Text(report.startedAt, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Ukupno trajanje") { Text("\(report.durationSeconds, specifier: "%.1f") s") }
                    LabeledContent("Najviša izmjerena memorija", value: report.peakMemoryBytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(clamping: report.peakMemoryBytes), countStyle: .memory) : "Mjerenje nije dostupno")
                    LabeledContent("Toplinsko stanje prije", value: thermalLabel(report.thermalBefore))
                    LabeledContent("Toplinsko stanje poslije", value: thermalLabel(report.thermalAfter))
                    LabeledContent("Izlazni znakovi", value: String(report.outputCharacters))
                    LabeledContent("Brzina teksta") { Text("\(report.charactersPerSecond, specifier: "%.1f") znakova/s") }
                    if let speed = report.tokensPerSecond {
                        LabeledContent("Brzina generiranja") { Text("\(speed, specifier: "%.1f") tokena/s") }
                    } else {
                        Text("Broj tokena nije izmjeren za ovu obradu.").font(.caption).foregroundStyle(.secondary)
                    }
                    if report.wasInterrupted { Label("Obrada je prekinuta", systemImage: "pause.circle").foregroundStyle(.orange) }
                }
            }
        }
        .navigationTitle("Lokalno izvođenje")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func thermalLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "nominal": return "Normalno"
        case "fair": return "Povišeno"
        case "serious": return "Visoko"
        case "critical": return "Kritično"
        default: return value
        }
    }

    private func modelLabel(_ value: String) -> String {
        LocalModelKind(rawValue: value)?.title ?? value
    }
}
