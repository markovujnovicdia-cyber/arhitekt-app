import SwiftUI

@MainActor struct CloudSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = AIConfiguration.savedURL
    @State private var token = ""
    @State private var message: String?
    @State private var checking = false
    @State private var connectionTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section("Privatni AI poslužitelj") {
                TextField("https://vas-posluzitelj.hr", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Pristupni token uređaja", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Ovdje se unosi token vašeg backenda, a ne OpenAI API ključ. API ključ postoji isključivo na poslužitelju. Prazno polje zadržava ranije spremljeni token za istu adresu.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Spremi postavke") {
                    do { try AIConfiguration.save(address: address, token: token); token = ""; message = "Postavke su spremljene. Cloud slanje zahtijeva zasebnu suglasnost za svaku obradu." }
                    catch { message = error.localizedDescription }
                }
                Button("Spremi i provjeri vezu", systemImage: "network") {
                    connectionTask = Task { @MainActor in
                        checking = true
                        defer { checking = false }
                        do {
                            try AIConfiguration.save(address: address, token: token)
                            token = ""
                            try await CloudAIClient().checkConnection()
                            message = "Veza s poslužiteljem i pristupni token su ispravni. Nisu poslani projektni podaci niti je pozvan AI model. Ispravnost OpenAI računa provjerava se prvom obradom."
                        } catch is CancellationError {
                            message = "Provjera je prekinuta."
                        } catch { message = error.localizedDescription }
                    }
                }
                if checking { ProgressView("Provjeravam vezu…") }
                Text("Ako koristite besplatni hosting, prvo buđenje poslužitelja može potrajati. Ako provjera istekne, pričekajte pa pokušajte ponovno.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Ukloni postavke i token", role: .destructive) {
                    AIConfiguration.remove(); address = ""; token = ""; message = "Cloud pristup je uklonjen. Lokalni podaci ostaju sačuvani."
                }
            }
            .disabled(checking)
            Section("Što se šalje") {
                Text("Transkripcija šalje dijelove odabrane audio snimke vašem poslužitelju i njegovu pružatelju AI usluge. Analiza šalje odabrani transkript i ograničene izvatke projektne memorije. Pitanja šalju samo pregledane izvore.")
                Text("Bez konfiguracije i interneta rade snimanje, pauza, pregled i ispravci transkripata, lokalna memorija, pretraživanje i sigurnosne kopije. Cloud AI analiza bez interneta nije dostupna.")
            }
        }
        .navigationTitle("Cloud AI")
        .onDisappear { connectionTask?.cancel() }
        .alert("Cloud postavke", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("U redu", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
}
