# Arhitekt Office 2.0 — potpuno lokalno

Izvorna iPhone aplikacija za hrvatskog arhitekta. Ciljani uređaj je **iPhone 16 Pro, A18 Pro, 8 GB RAM-a**. SwiftUI i SwiftData, SQLite FTS5, stvarni **whisper.cpp** i **llama.cpp** pogoni. Minimalni deployment iOS17; iPhone16Pro koristi iOS18 ili noviji.

**Nema backenda, API ključeva, mrežnog AI-ja niti mrežnog zamjenskog rješenja.** Aplikacija nema HTTP klijent i ne preuzima modele. Zvuk, transkripti, analiza, dohvat, upiti i metrike obrađuju se na uređaju. Ranija cloud konfiguracija uklonjena je; postojeće uredske informacije i izvorne revizije ostaju dostupne.

## Važno o stanju isporuke

Implementirani su svi lokalni integracijski slojevi i korisnički tijekovi. Oba prava C++ pogona kompilirana su i testirana na Linuxu. **iOS/Xcode/Metal kompilacija, stvarni Whisper/Qwen modeli, hrvatsko diktiranje i rad na iPhoneu16Pro nisu potvrđeni u ovom okruženju.** Te provjere nisu zamijenjene cloud obradom.

Izvorni kod je kompletan, ali generirane Apple biblioteke i težine modela nisu u ZIP-u. Prije lokalnog AI-ja na iPhoneu treba na Macu izraditi dva XCFrameworka i lokalno uvesti modele. Otvaranje projekta bez njih omogućuje rad s uredskim podacima, ali AI tada jasno javlja da izvorne biblioteke nedostaju. To nije alternativni AI pogon.

## Izrada i instalacija

Na Macu trebaju puni **Xcode16+**, iOS SDK, Git, Python3 i CMake3.24+.

```sh
# Jednokratno instalirajte CMake ako ga nemate:
brew install cmake
# U korijenu preuzetog projekta:
tools/build-local-engines.sh --platform ios --jobs 4
```

Skripta preuzima službene whisper.cpp i llama.cpp izvore na točno zaključanim commitovima iz `Native/upstream-lock.json`, provjerava ih, izrađuje oba pogona za uređaj/simulator i ponovno generira Xcode projekt. Ne preuzima modele i ne čita poslovne podatke. Nakon prvog dohvata izrada može koristiti predmemorirane izvore. [Detalji izrade](Native/README.md).

1. Otvorite **ArhitektOffice.xcodeproj** i shemu **ArhitektOffice**.
2. U Frameworks moraju biti povezana i ugrađena oba `Native/Artifacts/*.xcframework`. Generator to automatski postavlja kada datoteke postoje. Nemojte pokušavati povezati dvije kopije GGML-a kao statičke biblioteke.
3. Za vlastiti iPhone odaberite Development Team, jedinstveni Bundle Identifier ako je potreban, Developer Mode i povezani uređaj. Pokrenite `⌘R`.
4. U **zupčanik → Lokalni AI modeli i izvođenje** uvezite modele iz lokalne aplikacije Datoteke prema [uputi za modele](docs/LOKALNI-MODELI.md).
5. Počnite s višejezičnim **Whisper small**, zatim uvezite **Qwen3-1.7B Q4_K_M**. Medium je neobvezan i ne aktivira se automatski.

ZIP se ne instalira izravno na iPhone. Za gradnju iz izvora potreban je Mac/Xcode. Modeli se prenose na uređaj, primjerice AirDropom ili kabelom, nakon zasebnog preuzimanja na računalu. Za potpuno lokalne kopije odaberite „Na mojem iPhoneu”, ne mrežni file-provider.

## Dugo diktiranje i oporavak

Snimanje putem AVAudioRecordera stvara jedan **kontinuirani PCM CAF master** od16kHz, mono,16bit. Pauza/nastavak koriste isti zapis. Dnevnik oporavka nastaje prije mikrofona, ažurira se uz SwiftData, a snimanje može nastaviti pri zaključanom zaslonu preko audio background moda. Poziv i odspajanje mikrofona pauziraju snimanje; nastavak je ručan. Aplikacija ne snima zvuk telefonskog poziva: razgovor možete poslije prepričati.

Transkripcija čita male PCM prozore iz datoteke, bez učitavanja cijelog sastanka u RAM. Granice se biraju blizu tišine oko27sekundi, uz do1sekunde prethodnog zvuka i prethodnih100riječi kao Whisper kontekst. Svi izvorni okviri imaju pokrivenost. Vremenske oznake odstranjuju samo segment potpuno unutar ranije obrađenog konteksta; prijelazni segmenti i stvarna ponavljanja zadržavaju se. Moguće ponovljene rubne riječi korisnik ispravlja; nesigurno leksičko brisanje ne koristi se.

Nakon svakog prozora tekst se **prvo atomski sprema u kontrolnu točku**, a zatim u bazu. Nastavak provjerava izvor, plan prozora i SHA modela; uspješni dijelovi ne obrađuju se ponovno. Promjena modela ili izvora stvara novi dnevnik, ne prepisuje prethodni transkript. Neuspjeh i otkazivanje ne brišu snimku. Zasebne tipke razlikuju nastavak od ponovne obrade svih dijelova.

Potpuni transkript je uvijek dostupan. Svaka ručna ispravka stvara novu neizmjenjivu reviziju; dokazi ostaju vezani uz točan izvor. PCM čuva napisane audio okvire bez oslanjanja na završni MP4 indeks, ali prisilno gašenje iOS-a može izgubiti još nezapisane hardverske buffere. Nečitljiva djelomična datoteka ne briše se. Apsolutni „nula izgubljenih uzoraka” nije potvrđen niti obećan.

## Lokalna analiza i razgovor

Qwen3 radi kroz pravi llama.cpp, s isključenim thinking izlazom i JSON gramatikom. Cijeli transkript pokriva se uzastopnim prozorima, bez tihog odsijecanja na prvih nekoliko tisuća znakova. Svaki analizirani dio ima trajan dnevnik, pa prekid ne briše već validirane nacrte. Promjena izvora, modela ili konteksta odvojena je novim fingerprintom.

Prijedlozi mogu biti događaji/bilješke, činjenice, dogovori, odluke, planovi, zadaci, problemi, rokovi, promjene i otvorena pitanja. Svaki mora imati jedinstveni doslovni citat s UTF-16 rasponom u točnoj verziji transkripta. Nevaljani JSON, izmišljeni izvori ili prekinut izlaz zbog granice tokena odbijaju se bez zapisivanja djelomičnih zaključaka. Osoba i strukturirani datum prihvaćaju se samo ako su izričito podržani citatom; nejasni relativni rokovi ostaju tekst.

Mali model nema kalibriranu vjerojatnost točnosti. Automatske „potvrđene” tvrdnje zato se snižavaju na **neizvjesno** dok korisnik ne pregleda dokaz. Kategoriju, pouzdanost, osobu, rok, projekt i povezanost s ranijim događajem mijenja korisnik prije potvrde. Stari zapisi ne zamjenjuju se novim sažetkom. Izvor je uvijek sačuvan čak i kada je model nešto propustio; programsko pokrivanje svih prozora nije dokaz semantičke potpunosti.

„Pitaj ured” koristi **lokalni SQLite FTS5**: Unicode dijakritiku, prefikse, BM25, projektne/datumske/statusne filtre i izvatke iz svih dijelova dugih izvora. Indeks nije autoritativna baza; obnovi se prema SwiftData sadržaju nakon uređivanja ili uvoza kopije. Usklađivanje i pretraživanje rade na zasebnoj radnoj dretvi. Upiti o neriješenim problemima koriste trenutačni status; tjedni zadaci rok, a povijesno spominjanje datum izvora.

Odgovor ima izvore i datume. Bez relevantnih izvora model se ne učitava, nego se jasno kaže da podataka nema dovoljno. Izmišljene reference odbijaju se. FTS nije semantički embeddings indeks; parafraze bez zajedničkih pojmova mogu zahtijevati drugi pojam ili projektni filtar. Semantičku istinitost modela nije moguće dokazati samo gramatikom i citatima.

## Memorija, temperatura i brzina

Zajednički koordinator dopušta **samo jedan veliki pogon istodobno**. Svaki native poziv oslobađa kontekst i težine prije sljedećeg. Modeli se ne drže paralelno u memoriji. Najviše4CPU dretve, Metal/Accelerate na uređaju, najviše8192LLM kontekstnih tokena i ograničen izlaz. Prevelik kontekst vraća pogrešku umjesto tihog skraćivanja.

Pri ozbiljnom/kritičnom termalnom stanju, memory warningu, zaštitnom pragu fizičkog otiska ili odlasku aplikacije u pozadinu AI obrada se prekida i može nastaviti iz kontrolne točke. Aktivno audio snimanje zasebno nastavlja prema iOS audio pravilima. Pragovi su konzervativna zaštita, ne jamstvo protiv iOS jetsama.

U **Mjerenjima lokalnog izvođenja** nalaze se:

- vrijeme cijelog native poziva, uključujući učitavanje/oslobađanje;
- opaženi `phys_footprint` vrh, uzorkovan svakih100ms;
- stvarni broj emitiranih LLM tokena i tokeni/s za prefill+decode, odvojeno od ukupnog vremena;
- stanje temperature prije/poslije, prekidi i upozorenja memorije.

Za Whisper se ne izmišljaju LLM tokeni/s. Mjerenja ne sadrže transkript ili odgovor. Nema unaprijed izmišljenog rezultata brzine ili RAM-a za A18Pro. Medium može biti sporiji/topliji i mora se zasebno provjeriti na uređaju. [Protokol provjere](docs/TESTIRANJE.md).

## Pohrana i kopije

SwiftData čuva projekte, faze, zadatke, probleme, bilješke, snimke, revizije i potvrđenu memoriju. FTS5 je odvojeni obnovljivi indeks. Izvorni PCM zvuk, kontrolne točke i podaci imaju zaštitu do prvog otključavanja uređaja; Application Support isključen je iz automatskog backupa. Nema CloudKita ni sinkronizacije. Raniji backend token uklanja se iz Keychaina bez čitanja njegove vrijednosti.

JSON kopija sadrži podatke bez zvuka. Potpuni `.officebackup` uključuje mastere, metapodatke i dnevnike transkripcije; lokalni PCM prozori ne dupliciraju master. Stare kopije ostaju čitljive. Brisanje samo zvuka zadržava transkripte i tekstualne kontrolne točke, uključujući stanje nakon neuspješnog DB spremanja. Modeli i obnovljivi FTS indeks nisu u korisničkom paketu. Lokalni analitički nacrti u bazi izvoze se; regenerabilni fragmentni analysis cache nije zaseban poslovni izvor.

Kopije nisu aplikacijski šifrirane. Za potpuno lokalni rad izvozite na uređaj ili prenosite kabelom/AirDropom. Ako korisnik sam izabere mrežni servis u sistemskom biraču datoteka, taj prijenos je izvan lokalnog AI pogona; aplikacija ne pokreće vlastiti upload. Potpuni paket ograničen je na2GiB zvuka i20MB JSON-a. Ne brišite aplikaciju prije sigurnosne kopije.

## Testiranje i rezultati

```sh
# Stvarna SQLite FTS5 shema:
python3 tools/test_fts_index.py
# Linux CPU kompilacija stvarnih izvora i C ABI provjere:
tools/build-local-engines.sh --platform linux --jobs 4
# Statička Swift/Xcode provjera u Python venv-u:
python3 -m pip install -r tools/validation-requirements.txt
python3 tools/validate_project.py
```

Na Macu nakon native izrade:

```sh
xcodebuild build -project ArhitektOffice.xcodeproj -scheme ArhitektOffice \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ArhitektOffice.xcodeproj -scheme ArhitektOffice \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

Ime simulatora prilagodite Xcodeu. Simulator nije zamjena za A18Pro mjerenje. CI konfiguracija izrađuje native biblioteke prije iOS provjera; njezin udaljeni uspjeh nije pretpostavljen. [Stvarni rezultati](docs/REZULTATI.md), [native rezultati](Native/TEST-RESULTS.md), [upute za modele](docs/LOKALNI-MODELI.md).
