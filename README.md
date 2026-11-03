# Arhitekt Office

Izvorna iPhone aplikacija za samostalni arhitektonski ured u Hrvatskoj. SwiftUI, SwiftData i Apple Speech; iOS 17 ili noviji. Bez računa, pretplate, poslužitelja i API ključeva.

## Otvaranje i instalacija

1. Na Macu instalirajte **Xcode 16 ili noviji** i iOS Simulator. Otvorite `ArhitektOffice.xcodeproj` (projekt je već generiran; nema paketa ni dodatnih instalacija).
2. Odaberite shemu **ArhitektOffice** i iPhone simulator. Pokrenite **Product → Run** (`⌘R`).
3. Za vlastiti iPhone povežite uređaj, omogućite Developer Mode i odaberite ga kao odredište. U **Signing & Capabilities** odaberite svoj Apple Development Team. Po potrebi promijenite Bundle Identifier `com.arhitektoffice.app` u jedinstvenu vrijednost. Xcode može zatražiti prijavu Apple računa i povjerenje uređaja.
4. Pokrenite aplikaciju. Prvo dopuštenje za mikrofon i govor traži se tek kada uključite diktiranje. Osobni besplatni Apple račun podliježe Appleovim ograničenjima potpisivanja.

Sadržaj aplikacije je na hrvatskom, uz sistemske komponente koje slijede jezik iPhonea. Podržani su Dark Mode, dinamična veličina teksta i VoiceOver oznake osnovnih kontrola.

## Što aplikacija radi

- Projekti: unos i uređivanje naziva, broja, investitora, lokacije, vrste građevine, datuma početka; pretraživanje i arhiva. Vidljivi su otvoreni zadaci i neriješeni problemi.
- Četiri faze: Uvjeti, Idejni projekt, Glavni projekt i Završen. Svaka promjena ima zapis u povijesti; bilježi se posljednja aktivnost projekta.
- Zadaci: naziv, opis, projekt, neobvezni rok, prioritet i otvoren/izvršen status; središnji pregled s filtrima.
- Problemi: naziv, opis, projekt, datum, otvoren/riješen status i opis rješenja.
- Bilješke: kronološki pregled, pretraživanje, ručni unos, uređivanje i brisanje. Izvorni diktat čuva se uz potvrđeni unos.
- Diktiranje na hrvatskom (`hr-HR`): mikrofon → tekst → lokalni prijedlog projekta i kategorija → ispravci → potvrda spremanja. Projekt i kategorije uvijek se mogu ručno promijeniti. Uređivanje teksta dostupno je i bez mikrofona.
- Sigurnosna kopija: izvoz i uvoz verzioniranog JSON-a u Postavkama (zupčanik uz mikrofon). Uvoz provjerava format, verziju, veličinu, obvezna polja, identifikatore i povezanost podataka prije spremanja.

Pravila diktata prepoznaju izraze poput „trebam”, „moram”, „problem”, „nedostaje” i „nemamo”. To nisu jezični AI modeli: rezultat se obvezno pregledava. Rokovi i prioriteti ne izvode se iz govora; zadajte ih u uređivanju zadatka nakon spremanja. Naziv ili broj projekta mora se dovoljno jasno pojaviti u tekstu. Kod nejasnog odabira projekt se bira ručno.

## Privatnost i rad bez interneta

Svi uredski podaci nalaze se u trajnoj lokalnoj SwiftData bazi u aplikacijskom spremniku. Nema automatskog slanja podataka vanjskom AI servisu. CRUD, pretraživanje, pravila razvrstavanja i JSON kopije rade bez interneta.

Offline prepoznavanje hrvatskog govora ovisi o uređaju, iOS-u i dostupnim jezičnim modelima. Aplikacija preferira prepoznavanje na uređaju. Ako nije podržano, **prije mrežnog snimanja traži izričit pristanak** za Appleovo prepoznavanje. Odbijanje ne blokira ručni unos. Prekid, odbijeno dopuštenje i pogreške zadržavaju već dobiveni tekst za pregled. Speech prepoznavanje može vremenski ograničiti sesiju; za duže bilješke napravite više unosa.

JSON kopija sadrži i osjetljive podatke projekata i izvorne diktate u čitljivom obliku: spremite je na lokaciju kojoj vjerujete. Uvoz radi spajanje po stabilnim UUID-ovima: dodaje nove i obnavlja postojeće zapise iz kopije, bez brisanja ostalih zapisa. **Prije uvoza izvezite aktualno stanje**, jer starija kopija može zamijeniti novije podatke istog zapisa. Uvoz je spajanje, a ne povrat cijele baze u prijašnji trenutak: noviji zapisi koji nisu u kopiji ostaju sačuvani, uključujući povijest faza. Najveća veličina kopije je 20 MB. Izvoz nije zamjena za redovitu sigurnosnu kopiju; brisanje aplikacije briše njezin lokalni spremnik.

## Arhitektura

- `ArhitektOffice/App`: pokretanje trajne baze i četiri glavne kartice.
- `Models/OfficeModels.swift`: projekti, zadaci, problemi, bilješke i povijest faza; stabilni UUID-ovi, eksplicitni odnosi i kaskadna pravila.
- `Services`: neovisni parser diktata, upravljanje Speech/AVAudioEngine sesijom i validirane JSON kopije.
- `Views`: SwiftUI upiti i odvojeni obrasci; izmjene se spremaju izričito i prikazuju pogrešku pri neuspjehu.
- `ArhitektOfficeTests`: XCTest provjere parsera, pohrane, odnosa, sigurnosnih kopija i politike diktiranja.

Baza je namjerno konfigurirana s `cloudKitDatabase: .none`. Zadane vrijednosti, neobvezni inverse odnosi i odsutnost unique ograničenja pripremaju model za budući CloudKit. Stvarna iCloud sinkronizacija zahtijeva zasebno omogućavanje mogućnosti, migracijsku strategiju, pravila konflikata i testiranje; ova verzija je ne uključuje. Napredniji razvrstavač može zamijeniti `DictationParser` bez promjena pohrane ili obveznog mrežnog API-ja.

## Provjere

Na Macu:

```sh
xcodebuild -list -project ArhitektOffice.xcodeproj
xcodebuild build -project ArhitektOffice.xcodeproj -scheme ArhitektOffice \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
# Prilagodite ime simulatora onome dostupnom u Xcodeu:
xcodebuild test -project ArhitektOffice.xcodeproj -scheme ArhitektOffice \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

`⌘U` izvršava iste XCTest testove u Xcodeu. GitHub Actions konfiguracija u `.github/workflows/ios.yml` također radi simulator build i testove na macOS-u; izvršavanje tog CI-ja nije potvrđeno u ovoj isporuci. Za provjere fizičkog mikrofona, dopuštenja, prekida i restarta uređaja slijedite [ručne provjere](docs/TESTIRANJE.md).

Ova isporuka izrađena je u Linux okruženju bez Xcodea i Swift toolchaina. Statičke provjere strukture i sintakse opisane su u `docs/REZULTATI.md`. Za ponavljanje tih provjera koristite Python virtualno okruženje, instalirajte `tools/validation-requirements.txt` i pokrenite `python3 tools/validate_project.py`. **iOS build, XCTest i instalacija na stvarni iPhone ovdje nisu izvršeni.**

## Održavanje projekta

Xcode projekt je uključen i otvara se izravno. Ako dodajete datoteke izvan Xcodea, možete ponovno generirati projekt naredbom `python3 tools/generate_project.py` ili ih dodati u odgovarajući Xcode target. Generator treba samo Python 3 i reproducibilan je; pregazit će ručne promjene u `.pbxproj` i zajedničkoj shemi, pa sačuvajte vlastite postavke potpisivanja. `tools/generate_icon.py` regenerira priloženu ikonu i treba Pillow, koji nije ovisnost aplikacije.
