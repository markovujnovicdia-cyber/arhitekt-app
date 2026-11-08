# Lokalni Arhitekt Office 2.0 — 8. studenoga 2026.

## Stvarno izvršeno

Okruženje: Linux x86_64, GCC14.2.0, Python3.12.14 i CMake4.4.4. Nema Swift kompajlera, Xcodea ili fizičkog iPhonea.

- **Stvarni whisper.cpp i llama.cpp kompilirani su za Linux CPU** na zaključanim commitovima iz `Native/upstream-lock.json`. Kompilacija uključuje GGML i oba C++ adaptera, bez stubova za inferencijske funkcije.
- **7 C-ABI testova prošlo**, uz istodobno učitavanje oba pogona, provjeru izvoza samo vlastitih funkcija, nevaljane ulaze/model, otkazivanje i granice spremnika. Nema izvezenih GGML simbola koji bi se sudarili između pogona.
- **2 C++ testa prošla**: UTF-8/JSON escaping i stvarna upstream JSON gramatika. Provjereni su hrvatski znakovi, emoji, nepotpuni/nevaljani JSON i zabrana dodatnog teksta/think tagova.
- **11 SQLite FTS5 testova prošlo** nad stvarnom shemom iz `FTSIndex.swift` i SQLite3.53.1. Obuhvat: hrvatska dijakritika/prefiksi, BM25, svi dijelovi dugog izvora, vezani upiti, projekt/status/tjedni rokovi, transakcijski rollback i usklađivanje nakon obnove podataka.
- **40 Swift datoteka** uspješno statički parsirano; Xcode projekt, članstvo izvora, SQLite povezivanje, resursi, Info.plist, shema i ikona su valjani. Statički audit zabranjuje URLSession, Apple Speech mrežni put, CloudAIClient i OpenAI ključ u aplikacijskom kodu.
- Python alati i shell build skripta prolaze provjeru sintakse. `git diff --check` prolazi.

Detalji native provjera: `Native/TEST-RESULTS.md`.

## Izričito preskočeno ili neizvršeno

- **2 provjere sa stvarnim modelima preskočene**: hrvatski Whisper WAV i Qwen3 GGUF generiranje. Težine modela i stvarna hrvatska snimka nisu dostupni. Pokušaj dohvata Qwenove službene konfiguracije s Hugging Facea blokiran je HTTP403 mrežnom politikom; blokada nije zaobiđena. Službeni Qwen GitHub README je dostupan, a očekivana arhitektura ugrađena je u validator, ali stvarna datoteka modela nije njime provjerena ovdje.
- **Nisu izvršeni iOS/Metal build, Swift typecheck, SwiftData makroi ni XCTest.** Mac build skripta je pripremljena; Linux ne može potvrditi Apple XCFramework izradu. U ovom checkoutu nema generiranih iOS XCFrameworka, stoga trenutačno generirani Xcode projekt prikazuje0/2 native modula. Skripta ih na Macu izrađuje i regenerira projekt s oba link/embed zapisa.
- **Nema mjerenja na iPhoneu16Pro/A18Pro.** Nisu potvrđeni brzina, stvarni RAM vrh, temperatura, jetsam otpornost, hrvatska točnost, kvaliteta semantičke ekstrakcije ili20-minutna stvarna snimka. U aplikaciji su implementirani brojači i protokol za ta mjerenja; brojke nisu izmišljene.
- Udaljeni CI za ovu reviziju nije pretpostavljen uspješnim. iOS workflow prvo izrađuje native biblioteke pa tek aplikaciju/testove.

## Napisani testovi za Xcode

**80 XCTest metoda** uključeno je u test target; broj otkrivenih metoda nije prolaznost. Pokrivaju postojeću pohranu, revizije/provenanciju, lokalne audio prozore i resampliranje, nastavak/izvor/model fingerprint, kontrolne točke, očuvanje djelomičnog teksta pri brisanju zvuka, prenosive kopije, model GGML/GGUF validaciju i checksum, memorijsku/termalnu politiku, FTS5 i asinkrono pretraživanje te potpuno pokrivanje dugih sintetičkih tekstova.

Sintetički hrvatski testni tekst nije označen kao stvarni poslovni transkript. Provjere sheme/gramatike ne mjere semantičku točnost niti dokazuju da je Qwen1.7B dovoljno pouzdan za samostalne poslovne zaključke.

## Potvrđena arhitekturna svojstva koda

- iPhone aplikacija nema mrežni klijent, backend URL ili API ključ; nema cloud fallbacka. Stari backend, Render predložak i Apple Speech mrežni put uklonjeni su iz aktualne isporuke.
- Snimanje je kontinuirani lokalni CAF; PCM prozori su ograničeni na30sekundi i pokrivaju cijeli izvor. Svaki uspješan prozor ima atomsku kontrolnu točku prije baze. Rubna nesigurna ponavljanja ne brišu se leksičkim pravilima.
- Dva velika modela ne učitavaju se istodobno. Native konteksti/težine oslobađaju se prije otključavanja koordinatora; uvoz ili brisanje modela nije dopušteno tijekom inferencije.
- Prijedlozi i odgovori validiraju JSON, postojeće izvore i točne citate. Strojne potvrđene tvrdnje snižavaju se u neizvjesne; korisnik potvrđuje. Dosegnuta granica izlaznih tokena vraća pogrešku umjesto prihvata djelomičnih zaključaka.
- Stari izvori ne zamjenjuju se sažecima. Izvorni audio i povijest ostaju pri neuspjehu. Selektivno brisanje zvuka zadržava tekstualne dnevnike, a vidljiv djelomični oporavljeni transkript jasno je označen kao nepotpun.
- Lokalni modeli uvoze se iz Files. Validacija stvarnog zaglavlja i SHA radi u pozadinskom kopiranju; spremnik modela nije dio poslovne kopije. Application Support isključen je iz automatskog backupa. Ručni sistemski izvoz slijedi odredište koje korisnik odabere; za potpuno lokalnu kopiju odaberite lokalni uređaj/kabel/AirDrop.

## Preostale granice

FTS5 nije embeddings pretraživanje i može tražiti drukčiji pojam. Sačuvan izvor i pokrivenost svih prozora ne znače da je model razumio svaki detalj. Promjenjivi iOS resursi, model load i GPU operacije mogu se prekinuti tek kada native pogon obradi callback; zaštitni pragovi ne jamče izostanak iOS jetsama. Djelomične izvorne datoteke ostaju sačuvane i ako ih decoder ne može otvoriti.

Za potpune sljedeće provjere trebaju Mac/Xcode, lokalne navedene težine modela i stvarni iPhone16Pro. Koraci su u README.md, LOKALNI-MODELI.md i TESTIRANJE.md.
