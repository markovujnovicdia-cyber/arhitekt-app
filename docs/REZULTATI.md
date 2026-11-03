# Rezultati provjera — 3. studenoga 2026.

## Izvršeno u ovom okruženju

Okruženje: Linux, Python 3.12.14. Naredbe `command -v xcodebuild` i `command -v swift` nisu pronašle te alate.

- `tools/validate_project.py`: uspješno parsirano 15 Swift datoteka s Tree-sitter Swift parserom, bez sintaktičkih grešaka. Ovo nije Swift compiler niti provjera tipova.
- OpenStep/Xcode parser uspješno je učitao `project.pbxproj`; sve Swift datoteke uključene su u odgovarajuće source build faze.
- Provjerena je prisutnost svih referenciranih datoteka i resursa, valjanost `Info.plist` i obaju opisa dopuštenja, XML zajedničke sheme te JSON kataloga resursa.
- Provjereno je da ikona ima dimenzije 1024 × 1024 i RGB format bez alpha kanala.
- Ponovna generacija Xcode projekta i sheme daje identične SHA-256 sažetke; generator je ponovljiv.
- Python pomoćne skripte prolaze `py_compile`.
- Pregledana je povezanost modela, obrasci, mrežna privola i rukovanje prekidima. Popravljeni su višeredno razdvajanje diktata bez interpunkcije, zapis podnožja obrasca, zaštita prijepisa kod neuspjelog novog snimanja te spremanje diktata u glavni kontekst radi osvježavanja sučelja.

## Napisani testovi, ovdje NEIZVRŠENI

17 XCTest metoda: 14 u `DataServicesTests` i 3 u `SpeechPolicyTests`.

Obuhvat: hrvatski primjer diktata i izvorni tekst, razdvajanje višerednog unosa, dvosmisleni/arhivirani projekti, povijest faza, graf odnosa i JSON roundtrip, ponovljeni uvoz bez duplikata, obnavljanje zapisa, nevaljani podaci i verzije, ograničenje veličine, zaštita nespremljenih izmjena, sukobi vlasništva, sprečavanje gubitka nepovezanih zapisa pri izvozu, kaskadno brisanje izoliranog projekta, trajni spremnik i uređeni podaci nakon ponovnog otvaranja te politika mrežne privole.

Testovi stvarne baze koriste privremeni direktorij ili memorijski spremnik. Testovi politike govora ne pokreću mikrofon ni dijaloge dopuštenja.

## Nije izvršeno

- Swift/Apple SDK provjera tipova i SwiftData makroa.
- Xcode build, XCTest na simulatoru i GitHub Actions workflow.
- Instalacija na fizički iPhone, prepoznavanje hrvatskog govora, stvarni prekidi i dopuštenja.
- Zatvaranje aplikacije/restart fizičkog uređaja i provjera trajnosti na njemu.
- Objava u App Store, TestFlight ili objavljivanje cloud okruženja.

Projekt uključuje build/test shemu i macOS GitHub Actions workflow za nastavak provjere. Otvaranje u Xcodeu i testiranje na uređaju nužni su prije produkcijske uporabe. Upute su u `README.md` i `TESTIRANJE.md`.

## Ograničenja implementacije

Offline hrvatsko diktiranje ovisi o podršci uređaja. Rokovi i prioriteti unose se ručno. iCloud sinkronizacija nije uključena. JSON uvoz spaja i obnavlja zapise po UUID-u, a ne vraća cijelu bazu u prijašnji trenutak; zapisi izvan kopije ostaju, uključujući noviju povijest faza. Kopije su običan JSON, bez aplikacijskog šifriranja.
