# Povezivanje Arhitekt Officea s cloud AI-jem

Za ovo postavljanje ne trebate vlastiti server, domenu ni Docker na računalu. Render pokreće backend iz GitHuba i daje HTTPS adresu. GitHub repozitorij već sadrži `render.yaml`.

## 1. Pripremite OpenAI API račun

Otvorite [OpenAI API ključeve](https://platform.openai.com/api-keys), prijavite se i napravite ključ za ovaj projekt. Ako je potrebno, omogućite API naplatu u postavkama računa. ChatGPT pretplata i OpenAI API naplata odvojene su usluge.

Ključ čuvajte privatno. Unesite ga samo u Renderovo zaštićeno polje `OPENAI_API_KEY`. Ne šaljite ga u razgovor, GitHub ili iPhone aplikaciju. Prikazivanje/pisanje stvarne vrijednosti nije potrebno za ovu uputu.

## 2. Pokrenite backend na Renderu

Otvorite:

**[Postavi Arhitekt Office na Render](https://render.com/deploy?repo=https%3A%2F%2Fgithub.com%2Fmarkovujnovicdia-cyber%2Farhitekt-app)**

1. Prijavite se ili izradite Render račun. Ako traži pristup GitHubu, odaberite repozitorij `markovujnovicdia-cyber/arhitekt-app`.
2. Render će učitati Blueprint iz datoteke `render.yaml`. Naziv servisa je `arhitekt-office-ai`; ako nije dostupan, promijenite ga u jedinstveni naziv.
3. U traženo polje **OPENAI_API_KEY** zalijepite API ključ iz prethodnog koraka.
4. Pregledajte prikazani plan i uvjete, zatim potvrdite izradu/deployment. Predložak traži **Free** plan u Frankfurtu; dostupnost i eventualnu cijenu potvrđuje Renderov obrazac. Ako besplatni plan nije dostupan, nemojte automatski potvrditi plaćenu zamjenu bez pregleda.
5. Pričekajte uspješno pokretanje servisa. Render prikazuje njegovu HTTPS adresu, primjerice `https://vas-naziv.onrender.com`. Koristite stvarnu adresu prikazanu na servisu, ne ovaj primjer.

Automatsko objavljivanje svake buduće GitHub promjene isključeno je (`autoDeploy: false`). Kasnija ažuriranja pokrenite ručno u Renderu kada ih želite instalirati.

Besplatni servis može se uspavati zbog neaktivnosti. Prvo buđenje može potrajati; za povremenu osobnu uporabu najprije pokrenite provjeru veze. Plaćeni plan nije potreban za praćenje ove upute, a kasniju promjenu birate sami. AI API potrošnja obračunava se zasebno od hostinga.

## 3. Provjerite da je servis dostupan

U pregledniku otvorite stvarnu adresu servisa s dodatkom `/health`. Očekuje se:

```json
{"status":"ok"}
```

To znači da backend proces radi. Ne dokazuje ispravnost OpenAI ključa, kvotu ili kvalitetu modela.

U Renderovim postavkama varijabli servisa pronađite **DEVICE_ACCESS_TOKEN**. Render ga je automatski generirao kao zasebnu tajnu. Tu vrijednost kopirate samo u iPhone aplikaciju. Ona nije OpenAI ključ i može se neovisno promijeniti.

## 4. Spojite iPhone aplikaciju

U novoj verziji aplikacije:

1. Otvorite **zupčanik → Cloud AI poslužitelj**.
2. U adresu unesite bazni HTTPS URL servisa, bez završetaka `/health` ili `/v1`.
3. U **Pristupni token uređaja** zalijepite Renderovu vrijednost `DEVICE_ACCESS_TOKEN`.
4. Dodirnite **Spremi i provjeri vezu**.

Uspješna provjera potvrđuje URL, pristupni token i API ugovor. Ona ne šalje projekte ni snimke, ne poziva AI model i ne troši OpenAI tokene. OpenAI ovlasti/kvota provjeravaju se prvom stvarnom obradom. Token se čuva u Keychainu; ne morate ga ponovno upisivati svaki put.

Ako ste instalirali raniji ZIP, preuzmite aktualnu verziju iz GitHuba i ponovno je pokrenite u Xcodeu da dobijete novu tipku za provjeru. Za instalaciju izvornog iOS projekta i dalje je potreban Mac s Xcodeom; ZIP se ne može izravno instalirati na iPhone.

## 5. Kratka proba prije dugog sastanka

1. Dodajte projekt, primjerice „Kuća Cerje”.
2. Snimite 20–30 sekundi na hrvatskom, završite i preslušajte.
3. Otvorite snimku u Memoriji, pokrenite transkripciju i potvrdite slanje audio zapisa.
4. Provjerite cjeloviti tekst, zatim dopustite analizu pregledanog konteksta.
5. Ispravite prijedloge i spremite samo odabrane informacije.
6. U kartici Pitaj ured pronađite relevantne zapise, pregledajte ih i pošaljite probno pitanje.

Ta proba koristi stvarni AI API i može stvoriti API potrošnju. Snimanje i lokalni pregled bez slanja ne stvaraju takve API zahtjeve.

## Ako zapne

| Rezultat | Što provjeriti |
| --- | --- |
| Nema odgovora ili timeout | Pričekajte buđenje servisa, otvorite `/health` i ponovite provjeru. |
| HTTP 401 | U aplikaciju treba vrijednost `DEVICE_ACCESS_TOKEN`, a ne OpenAI ključ. Provjerite točan URL i kopiranje bez dodatnih znakova. |
| Veza prolazi, transkripcija HTTP 503 | U Renderu provjerite `OPENAI_API_KEY`, dostupnost modela i API naplatu/ovlasti. |
| HTTP 429 | Pričekajte pa ponovite. Može biti ograničenje backenda ili AI računa. |
| HTTP 502 pri analizi | AI nije vratio valjanu strukturu ili provjerljive izvore; transkript ostaje sačuvan. Pokušajte ponovno. |
| Servis se ne pokreće | Pregledajte Renderov deployment status; provjerite da je OpenAI ključ postavljen i da generirani token ima najmanje 32 znaka. |

Ako tražite pomoć, pošaljite samo adresu servisa, HTTP status ili tekst pogreške bez ključeva i tokena. Nemojte kopirati cijele varijable ili zapise koji sadrže povjerljive podatke.

## Što je pripremljeno, a što slijedi

Konfiguracija u repozitoriju, Dockerfile, API i aplikacijska provjera veze pripremljeni su. Backend nije objavljen samim spremanjem ovih datoteka: korisnik se prijavljuje u Render, unosi tajnu i potvrđuje deployment. Konkretan HTTPS URL postoji tek nakon tog koraka.
