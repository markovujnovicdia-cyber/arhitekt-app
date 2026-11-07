# Arhitekt Office 2.0

Izvorna iPhone aplikacija za hrvatski arhitektonski ured: dugo lokalno snimanje, potpuni transkripti s verzijama, trajna projektna memorija s dokazima i pitanja nad odabranim podacima. **SwiftUI + SwiftData, iOS 17+, Xcode 16+.** Bez API ključa ugrađenog u aplikaciju.

## Instalacija na iPhone

1. Preuzmite projekt i na Macu otvorite **ArhitektOffice.xcodeproj**. Nema Swift Package ovisnosti ni generiranja potrebnog za otvaranje.
2. Odaberite shemu **ArhitektOffice** i simulator ili vlastiti povezani iPhone.
3. Za uređaj u Signing & Capabilities odaberite svoj Apple Development Team i po potrebi jedinstveni Bundle Identifier. Na iPhoneu omogućite Developer Mode i povjerenje uređaju.
4. Pokrenite **Run** (`⌘R`). Mikrofon se traži tek pri prvom snimanju. Isprobajte najprije lokalni tijek bez cloud postavki.

Ova verzija nadograđuje postojeće modele dodatnim poljima i odnosima. Stare bilješke, projekti, zadaci i problemi ostaju u aplikaciji. Prije nadogradnje stvarne baze napravite sigurnosnu kopiju; automatska SwiftData migracija mora se provjeriti na Macu/iPhoneu prije produkcijske uporabe.

## Radni tijek

**Snimi razgovor → završi i sačuvaj → preslušaj → dopusti transkripciju → provjeri cijeli tekst → dopusti analizu odabranog konteksta → ispravi i potvrdi informacije.**

- Snimanje je kontinuirani lokalni PCM CAF zapis, a ne kratka Apple Speech sesija. Pauziranje i nastavak koriste isti master. Nema umjetnog ograničenja na 20 minuta; praktične granice su prostor, baterija i iOS.
- Dnevnik oporavka nastaje prije početka zvuka; ažurira se i baza. Nakon prekida ili ponovnog pokretanja sačuvani zapis vraća se u Memoriju. Audio se nikad ne briše zbog neuspjele transkripcije.
- Tek nakon završetka izrađuju se poredani AAC dijelovi do 60 sekundi, koji se šalju zasebno i redom. Svaki uspješan rezultat odmah se lokalno sprema; ponovni pokušaj preskače uspješne dijelove, a izričita ponovna obrada može ih ponovno poslati.
- Cijeli transkript ostaje sačuvan. Ispravci stvaraju novu verziju; ranije verzije i njihove reference ostaju dostupne. Ne prepisuju se sažetkom.
- AI analizira sve dijelove dugog teksta, uz prethodni prozor istog izvora i pregledani lokalni kontekst. Odvaja činjenice, dogovore, planove, prijedloge, neizvjesnosti, zadatke, probleme, odluke, promjene, rokove i otvorena pitanja.
- Svaki prijedlog ima provjereni doslovni citat i UTF-16 raspon iz točne verzije transkripta. Projekt, vrstu, pouzdanost, opis, osobu i rok uređuje korisnik prije potvrde. Ponovna potvrda istih prijedloga ne stvara iste zapise ponovno.
- Potvrđene informacije dodaju se kronološki. Zadaci i problemi povezani su s izvornim zapisom; promjena može upućivati na prethodni zapis bez njegova brisanja.
- Kartice: **Projekti, Zadaci, Problemi, Memorija, Pitaj ured**. Projekt prikazuje trenutačno stanje, otvorene stavke, potvrđene odluke i cjelovitu kronologiju. Memorija pretražuje i arhivu, snimke i sve verzije transkripata.

Prekid pozivom pauzira mikrofon; nastavite ručno. Snimanje u pozadini i pri zaključanom ekranu koristi deklarirani audio background mode. Aplikacija **ne snima zvuk telefonskog poziva**. Nakon razgovora možete prepričati sadržaj. CAF čuva napisane audio okvire bez ovisnosti o završnom MP4 indeksu, ali gašenje uređaja ili prisilni prekid može izgubiti još nezapisane hardverske buffere. Djelomične datoteke ostaju sačuvane za oporavak; apsolutni gubitak nula uzoraka ne jamči se.

## Jednostavno postavljanje

Nemate server? Slijedite [kratke Render upute](docs/JEDNOSTAVNO-POSTAVLJANJE.md) ili otvorite [postavljanje na Render](https://render.com/deploy?repo=https%3A%2F%2Fgithub.com%2Fmarkovujnovicdia-cyber%2Farhitekt-app). Predložak traži Free plan, automatski generira token uređaja i traži da OpenAI ključ unesete izravno u Render. Pregledajte plan prije potvrde.

## Cloud AI konfiguracija

Snimanje, pauza, pohrana, pregled, ručne ispravke, lokalno pretraživanje i sigurnosne kopije rade bez interneta. **Napredna transkripcija, semantička analiza i odgovori zahtijevaju backend, internet i AI račun.** Modeli se ne izvršavaju na iPhoneu i nema obećanja offline AI-ja.

Backend je u [backend/](backend/README.md): Node.js 24+, bez dodatnih npm paketa, odvojeni token uređaja, provjereni strukturirani odgovori, ograničenja veličine i vremena, bez spremanja sadržaja na poslužiteljski disk. Stvarni OpenAI ključ postavlja se isključivo kao `OPENAI_API_KEY` na poslužitelju. Nemojte ga unositi u iPhone ni Git.

1. Postavite backend na svoj poslužitelj prema njegovu README-u. Podesite `OPENAI_API_KEY` i slučajni `DEVICE_ACCESS_TOKEN` od najmanje 32 znaka kroz sigurne server postavke.
2. Osigurajte HTTPS domenu s valjanim certifikatom i reverse proxyjem prema backendu. Zadano sluša na loopback adresi; nema javnog deploymenta uključenog u ovu isporuku.
3. U iPhone aplikaciji otvorite **zupčanik → Cloud AI poslužitelj**, unesite baznu HTTPS adresu bez `/v1` i **token uređaja**, ne OpenAI ključ. Token je u Keychainu i vezan uz točnu konfiguriranu adresu. Preusmjeravanja HTTP zahtjeva odbijaju se.
4. Snimite kratak probni razgovor i zasebno dopustite slanje zvuka. Pri analizi pregledajte transkript, projekte i prethodne zapise koji će se poslati. Trošak stvarne cloud obrade ovisi o vašem pružatelju/računu.

Zadani modeli: `gpt-4o-transcribe` za hrvatski govor i `gpt-4.1-mini` za strukturiranu analizu i odgovore. Podrška je provjerena u službenim OpenAI OpenAPI/SDK izvorima dostupnim iz okruženja; detalji i ograničenja provjere u backend README-u. Dostupnost vašem računu provjerava se tek stvarnim API pozivom.

„Pitaj Arhitekt Office” prvo radi lokalni dohvat. Pregledate točne izvatke, uklonite neželjene izvore i zasebno dopustite slanje pitanja. Uz odgovor se prikazuju izvorni zapisi i datumi. Bez izvora daje se izričita obavijest da nema dovoljno podataka. Provjera citata ograničava izvore, ali ne može matematički jamčiti semantičku točnost modela; pregled ostaje potreban. Lokalni dohvat koristi pretraživanje teksta, prefikse i datumske filtre, a ne embeddings; za drugačije formulacije pokušajte naziv projekta ili drugi pojam.

## Sigurnosne kopije i privatnost

**Zupčanik → Kopija podataka i audio snimki** izvozi paket `.officebackup` s JSON podacima i zvukom. To je potpuna prenosiva kopija; za iCloud Drive ili drugo odredište koristite sistemsku aplikaciju Datoteke. Paket je obična mapa dokumenta, bez aplikacijskog šifriranja, pa odaberite sigurno odredište. Audio povećava veličinu: 20 minuta 16 kHz mono PCM-a približno je 38 MB prije AAC kopija.

JSON izvoz ostaje dostupan za interoperabilnost, ali **ne sadrži audio bajtove**. V2 format čuva metapodatke, transkripte, AI nacrte i memoriju; uvoz v1 formata ostaje podržan. Uvoz spaja zapise po UUID-u, ne briše ostale zapise i čuva neizmjenjive izvorne verzije. Paket provjerava putanje, simboličke veze, veličine i sukobe datoteka. Jednaki postojeći audio zapisi ne prepisuju se; različiti sadržaj istog puta odbija se. Paket je ograničen na 2 GiB; JSON na 20 MB.

Zvuk i dnevnik imaju iOS zaštitu `completeUntilFirstUserAuthentication`, koja omogućuje nastavak snimanja nakon zaključavanja tek nakon prvog otključavanja uređaja. Lokalna baza ostaje u sandboxu aplikacije. Cloud slanje traži izričitu privolu za svaku operaciju. Moguće je obrisati samo audio uz očuvanje transkripata i memorije. Brisanje aplikacije uklanja njezine lokalne podatke. iCloud sinkronizacija nije uključena; modeli su pripremljeni za buduću zasebno testiranu nadogradnju.

## Testiranje i struktura

- `App/`: trajna baza, oporavak na pokretanju i navigacija.
- `Models/`: postojeći uredski modeli + snimke, dijelovi, verzije transkripta i memorija.
- `Services/`: audio, oporavak, Keychain konfiguracija, AI klijent, dohvat, obrada, potvrda, kopije.
- `Views/`: snimanje, potpuni transkripti, pregled AI prijedloga, kronologija i pitanja.
- `backend/`: zaseban provjerljiv HTTP integracijski sloj.

```sh
# Linux ili Mac, stvarni lokalni backend testovi s lažnim AI providerom:
cd backend
npm ci --ignore-scripts
npm test
```

Na Macu u korijenu projekta:

```sh
xcodebuild build -project ArhitektOffice.xcodeproj -scheme ArhitektOffice \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ArhitektOffice.xcodeproj -scheme ArhitektOffice \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

Ime simulatora prilagodite svojem Xcodeu. `⌘U` pokreće XCTest. GitHub Actions uključuje iOS i backend provjere. Stvarna hrvatska transkripcija, mikrofon, prekidi, pozadina i migracija baze zahtijevaju provjeru na uređaju prema [TESTIRANJE.md](docs/TESTIRANJE.md).

U ovom Linux okruženju **nema Swift/Xcode toolchaina**. Backend testovi i statičke provjere su izvedivi; iOS build, XCTest i instalacija nisu izvršeni. Rezultati su u [REZULTATI.md](docs/REZULTATI.md). Backend nije objavljen i stvarni AI pozivi nisu testirani bez konfiguriranih ključeva.

Xcode projekt je već generiran. Ako dodate izvore izvan Xcodea, `python3 tools/generate_project.py` obnavlja projekt/sheme i pregazit će ručne Xcode postavke. Statički validator: u Python virtualnom okruženju instalirajte `tools/validation-requirements.txt` i pokrenite `python3 tools/validate_project.py`; on ne zamjenjuje Apple SDK build.
