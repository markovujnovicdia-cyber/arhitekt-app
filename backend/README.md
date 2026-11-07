# Arhitekt Office 2.0 — privatni AI posrednik

Node.js 24+, bez dodatnih npm paketa. API ključ ostaje na poslužitelju. iPhone koristi zaseban opoziv pristupni token spremljen u Keychainu i HTTPS URL vašeg poslužitelja. Ovo je posrednik za jednog korisnika/ured, a ne javni višekorisnički servis.

## Pokretanje

```sh
cd backend
cp .env.example .env
# Uredite .env lokalno na poslužitelju; ne šaljite vrijednosti u chat ili Git.
# OPENAI_API_KEY: vaš poslužiteljski OpenAI ključ.
# DEVICE_ACCESS_TOKEN: vlastiti slučajni niz od najmanje 32 znaka.
# openssl rand -hex 32
npm ci --ignore-scripts
npm test
npm start
```

`.env` je ignoriran. Nema runtime npm ovisnosti; `npm ci` služi provjeri reproducibilnog lockfilea. Backend odbija pokretanje bez potrebnih vrijednosti. Zadano sluša samo `127.0.0.1:8080`. Ne izlažite ga internetom bez TLS reverse proxyja. Za kontejner postavite `HOST=0.0.0.0`; port objavite samo reverse proxyju.

Prije uporabe na iPhoneu osigurajte vlastitu domenu s valjanim javnim TLS certifikatom. U aplikaciji unesite bazni HTTPS URL bez `/v1` i pristupni token. OpenAI ključ se nikad ne unosi u aplikaciju. Prije transkripcije i AI obrade aplikacija mora zatražiti suglasnost za slanje odabranog audio dijela/prijepisa i konteksta. Backend ne traži ni sprema Apple Speech dopuštenja.

`GET /health` vraća `{ "status": "ok" }` i provjerava da proces odgovara; ne potvrđuje dostupnost, kvotu ni ovlasti OpenAI računa.

## HTTP ugovor

Za sve `POST` operacije potreban je `Authorization: Bearer <DEVICE_ACCESS_TOKEN>`.

### `POST /v1/transcribe`

`multipart/form-data`, točno jedno polje `file` s podržanom audio datotekom. Maksimalno **20 MiB po audio dijelu**, uz 64 KiB dopuštenog multipart omota. `.m4a`/AAC iz iPhonea je podržan. Odgovor:

```json
{ "text": "Cjeloviti prijepis poslanog audio dijela." }
```

Posrednik koristi OpenAI `POST /v1/audio/transcriptions`, zadano `gpt-4o-transcribe`, `language=hr`, `response_format=json`. Model je konfigurabilan kroz `TRANSCRIPTION_MODEL`; podržane konfiguracije u ovoj verziji: `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-transcribe`. Provider naposljetku provjerava format i dostupnost modela računu. iPhone dijeli dugo snimanje i šalje dijelove redom; ovaj endpoint ne spaja audio niti drži međusesijsko stanje. Ponavljanje neuspjelog dijela ne smije obrisati lokalnu snimku.

### `POST /v1/analyze`

```json
{
  "transcript": { "id": "10000000-0000-4000-8000-000000000001", "text": "Trebam nazvati statičara." },
  "projects": [{ "id": "20000000-0000-4000-8000-000000000002", "name": "Kuća Cerje", "number": "2026-01" }],
  "context": []
}
```

Prijepis je jedan fragment do **30000 UTF-16 jedinica**. Klijent može slati manje fragmente i mora premjestiti vraćene UTF-16 pozicije na izvorni cjeloviti prijepis. Fragmentacija ne smije prepisati ili skratiti trajno spremljeni izvor.

Odgovor:

```json
{
  "summary": "Spomenut je poziv statičaru.",
  "proposals": [{
    "id": "40000000-0000-4000-8000-000000000004",
    "projectID": "20000000-0000-4000-8000-000000000002",
    "kind": "task",
    "certainty": "planned",
    "title": "Nazvati statičara",
    "details": "Trebam nazvati statičara.",
    "responsible": null,
    "dueDate": null,
    "source": {
      "transcriptID": "10000000-0000-4000-8000-000000000001",
      "startUTF16": 0,
      "endUTF16": 24,
      "quote": "Trebam nazvati statičara."
    },
    "relatedEntryID": null
  }]
}
```

Primjer pozicija služi objašnjenju; server ih uvijek izračunava iz stvarne duljine citata. `endUTF16` je isključiv. `id` generira server; nije ključ za trajno uklanjanje duplikata. Klijent treba odbiti ponovnu potvrdu iste kombinacije izvorne revizije, raspona i kategorije. Server uklanja jednake prijedloge unutar jednog odgovora.

Kategorije: `note`, `task`, `issue`, `decision`, `question`, `agreement`, `change`, `deadline`, `fact`, `plan`, `summary`. Izvjesnost: `confirmed`, `planned`, `proposed`, `uncertain`. `projectID` može biti `null` kada projekt nije siguran; korisnik ga bira prije spremanja. `dueDate` je `null` ili valjan kalendarski `YYYY-MM-DD`. Nejasni relativni rokovi ostaju u opisu. `relatedEntryID` može upućivati samo na zapis iz poslanog konteksta koji ima `recordType="memory"`.

Model daje doslovan citat; posrednik potvrđuje da se citat pojavljuje točno jednom i sam računa pozicije. Izmišljeni ili dvosmisleni izvori odbijaju se pogreškom 502, bez pretvaranja u prividno valjane prijedloge. Provjera izvora ne može dokazati potpunu semantičku točnost modela: korisnikov pregled i potvrda ostaju obvezni.

### `POST /v1/ask`

```json
{
  "question": "Što je investitor tražio?",
  "context": [{
    "id": "30000000-0000-4000-8000-000000000003",
    "projectID": "20000000-0000-4000-8000-000000000002",
    "date": "2026-11-07T08:00:00Z",
    "title": "Sastanak",
    "text": "Investitor je tražio pregled nacrta u petak."
  }]
}
```

Odgovor: `{ "answer": "...", "sourceIDs": ["..."], "insufficientData": false }`. Citirani ID-ovi moraju postojati u poslanom kontekstu. Odgovor bez potpore ne može biti označen kao dovoljan. Za prazan kontekst odmah se vraća `insufficientData=true`, bez naplativog poziva modelu. Pitanje je ograničeno na 3000 UTF-16 jedinica.

Kontekst za obje operacije: do 40 jedinstvenih zapisa, do 12000 UTF-16 jedinica teksta po zapisu, do 80000 ukupno s naslovima. Zapisi nose `id`, `projectID` (UUID ili null), `date`, `title`, `text` i neobvezni `recordType` (`memory`, `note`, `transcript`, `task`, `issue`, `record`; bez polja tretira se kao opći zapis). Citati odgovora mogu upućivati na sve vrste; `relatedEntryID` samo na `memory`. Projekti: do 500, uz UUID i neprazan naziv. Klijent radi dohvat lokalno i šalje samo relevantne odabrane zapise. Povijest, izvorni prijepisi i audio nikad se ne zamjenjuju odgovorom modela.

## Modeli i provjera službenih izvora

Provjereni su službeni OpenAI izvori dostupni 7. studenoga 2026. iz ovog okruženja:

- [OpenAI OpenAPI specifikacija](https://github.com/openai/openai-openapi/blob/master/openapi.yaml), `CreateTranscriptionRequest`, `/audio/transcriptions`, `gpt-4.1-mini` u modelima.
- [Službeni Node SDK: audio transcriptions](https://github.com/openai/openai-node/blob/master/src/resources/audio/transcriptions.ts), podržani modeli, `json` format i audio formati.

Stranice `platform.openai.com/docs/guides/speech-to-text` i `developers.openai.com/api/docs/guides/structured-outputs` mrežna politika blokirala je odgovorom 403. Aktualno službeno ograničenje veličine prijenosa nije neovisno potvrđeno na tim stranicama; **20 MiB je naše eksplicitno lokalno ograničenje**. Dostupnost modela i kvota ovise o vašem OpenAI računu i mogu se promijeniti. Prije produkcije provjerite službenu dokumentaciju/deprecations; novi `TRANSCRIPTION_MODEL` mora biti kompatibilan s JSON odgovorom. Ovdje nisu izvršeni stvarni OpenAI pozivi jer nije konfiguriran račun/ključ.

Analiza i pitanja koriste `POST /v1/chat/completions` s `gpt-4.1-mini` i `response_format=json_schema`, `strict=true`. `ANALYSIS_MODEL` se može promijeniti samo na model koji podržava taj ugovor. Odgovor s odbijanjem, prekidom zbog duljine ili nevaljanom strukturom odbija se; ne sprema se djelomičan rezultat kao potvrđena činjenica.

## Operativna sigurnost i ograničenja

- Audio i tekst drže se samo u radnoj memoriji zahtjeva; nema diska, baze, access logova ni zapisa transkripta. OpenAI obrada podliježe uvjetima i pravilima zadržavanja vašeg računa; ovaj posrednik ne tvrdi da ih isključuje.
- Pristupni token uspoređuje se hashiranjem i vremenski stalnom usporedbom. Jedan token znači jedan sigurnosni opseg; za više korisnika treba zasebna autentikacija, izolacija i revizija ovlasti.
- Provjera formata, ograničenja JSON-a, nepoznatih izvora i kalendarskih datuma vrši se prije vraćanja prijedloga.
- Maksimalno 2 istodobna zahtjeva i 30 zahtjeva/minuti po procesu. To je zaštita procesa, ne raspodijeljeno ograničavanje između više replika. iPhone treba obrađivati audio dijelove redom. `429` sadrži `Retry-After: 60`.
- Rok OpenAI poziva je zadano 120 s po dijelu, podesiv 1–300 s. Prijenos ulaznog HTTP zahtjeva ima rok 30 s. Povećajte ga u kodu/reverse proxyju samo nakon procjene sporih veza.
- Svaki neuspjeli poziv vraća samo sanitiziranu poruku; providerovi odgovori s pogreškom i tokeni ne vraćaju se klijentu. Bez automatskih poslužiteljskih retryja, da se ne skrivaju dodatni troškovi. Lokalna aplikacija može ponoviti obradu sa sačuvanim izvornikom.
- Tekstovi su nepouzdani podaci. Sistemske upute zabranjuju promjenu pravila kroz tekst prijepisa; citati se dodatno provjeravaju. To smanjuje rizik prompt injectiona, ali ne zamjenjuje korisnikov pregled.
- HTTPS certifikat, reverse proxy, siguran unos/rotacija ključeva i uređajskog tokena obvezna su konfiguracija administratora prije produkcijske uporabe.

## Testovi

`npm test` izvršava Node `node:test` integracijske testove s pravim lokalnim HTTP serverom i lažnim providerom; ne zahtijeva ključeve ni internet. Pokriveni su autorizacija, cijeli multipart prijenos, redoslijed dijelova, preveliki/dugi ulazi, UTF-16 citati, duplikati, nevaljani izvori, datumi, prazni kontekst, izmišljene reference, API greške, timeout put, nepotpuni strukturirani odgovori i čuvanje osjetljivih detalja u pogreškama. Ti testovi ne dokazuju kvalitetu stvarne hrvatske transkripcije ili semantičku točnost cloud modela.
