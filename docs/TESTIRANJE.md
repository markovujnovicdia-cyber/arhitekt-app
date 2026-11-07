# Ručne provjere na iPhoneu

Ovo je kontrolni popis za izvršavanje, a ne tvrdnja da su provjere provedene.

1. **Prvi start:** otvorite aplikaciju na iOS-u 17+. Baza je prazna; nema demo podataka. Uključite Dark Mode i veći tekst. Provjerite da su kartice i mikrofon dostupni.
2. **Projekt:** dodajte „Kuća Cerje”, broj „2026-01”, investitora, lokaciju, vrstu i datum. Uredite podatke, pronađite ga pretraživanjem. Promijenite fazu dvaput i provjerite datiranu povijest. Arhivirajte i ponovno aktivirajte projekt.
3. **Zadaci:** dodajte zadatak s rokom i visokim prioritetom. Provjerite filtre po projektu, roku, prioritetu i statusu. Označite izvršenim i provjerite broj otvorenih zadataka na projektu. Uredite i izbrišite zadatak uz potvrdu.
4. **Problemi:** dodajte problem, promijenite ga u riješen i unesite opis rješenja. Provjerite broj neriješenih problema, filter statusa i prikaz rješenja pri ponovnom uređivanju.
5. **Bilješke:** dodajte i uredite bilješku, potražite po tekstu i projektu, izbrišite uz potvrdu. Provjerite datum/vrijeme i kronološki redoslijed.
6. **Diktat:** „Kuća Cerje. Danas sam razgovarao s investitorom. Geodet će poslati podlogu u petak. Trebam nazvati statičara. Problem je što još nemamo vlasnički list.” Zahtijevajte pregled prepoznatog teksta, prijedlog projekta, bilješke, zadatak i problem. Ispravite kategoriju i tekst, promijenite projekt i spremite. Provjerite izvornu verziju diktata. Odustajanje ne smije spremiti podatke.
7. **Dopuštenja:** odbijte mikrofon, zatim govor (na svježoj instalaciji ili resetiranim dopuštenjima). Aplikacija mora objasniti problem i dopustiti tipkanje. Vratite dopuštenja u sistemskim Postavkama i pokušajte ponovno.
8. **Offline:** s uključenim zrakoplovnim načinom provjerite CRUD i parser. Diktiranje provjerite samo ako `hr-HR` na uređaju podržava lokalno prepoznavanje. Ako ne podržava, odbijte Apple mrežni način i koristite ručni unos; aplikacija ne smije započeti snimanje bez pristanka.
9. **Prekidi:** tijekom diktiranja zaključajte iPhone, pošaljite aplikaciju u pozadinu ili primite poziv. Započnite novu sesiju poslije prekida; mikrofon ne smije ostati aktivan, a postojeći tekst mora biti dostupan. Ponovite početak/zaustavljanje nekoliko puta.
10. **Trajnost:** zatvorite aplikaciju iz multitaskinga, ponovno otvorite; zatim ponovno pokrenite iPhone. Svi potvrđeni podaci i odnosi moraju ostati sačuvani.
11. **Kopije:** izvezite JSON. Uvezite ga u praznu instalaciju/drugi testni uređaj i usporedite sva polja, arhivu, povijest, rokove, prioritete, rješenja i izvorni diktat. Ponovite uvoz: nema duplikata. Uvezite stariju kopiju i provjerite dokumentirano obnavljanje istih UUID-ova.
12. **Nevaljane kopije:** pokušajte učitati oštećen JSON, pogrešnu verziju, prazni naziv, nevaljan enum, ponovljeni UUID i >20 MB datoteku. Odbijanje ne smije izmijeniti postojeću bazu. Otkazivanje birača datoteke ne smije izgubiti podatke.

Automatski testovi nad trajnim spremnikom koriste privremeni direktorij i ne diraju stvarnu bazu aplikacije. Speech dopuštenja, podrška za jezik i fizički mikrofon trebaju stvarni uređaj i ručno testiranje.

## Dodatne provjere verzije 2.0

- Prije nadogradnje sačuvajte bazu verzije1. Otvorite istu bazu u v2; postojeći projekti, odnosi, datumi i bilješke moraju ostati dostupni.
- Snimite najmanje20 minuta, uključujući hrvatske nazive, osobe, rokove, pretpostavke i nekoliko projekata. Pauzirajte pa nastavite; preslušajte prije i poslije pauze. Zaključajte zaslon5min pa otključajte. Provjerite završni CAF i ukupno trajanje.
- Snimajte offline, završite, zatvorite aplikaciju i ponovno je otvorite. Tek poslije mrežne dostupnosti i privole transkribirajte. Usporedite cijeli tekst s audio zapisom, posebice granice60s AAC dijelova. Ne očekujte vremenske oznake pojedine riječi u ovoj verziji.
- Prekinite proces tijekom snimanja. Nakon otvaranja mora se pojaviti oporavljena snimka, uz upozorenje. Provjerite čitljivost parcijalnog CAF-a; ako nije čitljiv, datoteka se ne smije izbrisati. Hardverski gubitak zadnjih nezapisanih buffera nije moguće isključiti.
- Provjerite poziv, Bluetooth odspajanje, odbijeno dopuštenje, nedostatak slobodnog prostora i otkazivanje pripreme. Snimanje se ne smije automatski nastaviti bez korisnikova znanja poslije prekida.
- Simulirajte pogrešan backend token, HTTP429/500, nestanak interneta i timeout na srednjem dijelu. Uspješni dijelovi ostaju, izvorni master ne nestaje. Ponovni pokušaj nastavlja od neuspjelog dijela. Kod praznog prijepisa dijela aplikacija traži pregled/retry ili ručni transkript.
- Ispravite transkript i spremite novu verziju. Stara verzija i svi citati na nju ostaju nepromijenjeni. Ponovite transkripciju; stare ispravke se ne prepisuju.
- Prije analize uklonite neke projekte i kontekst iz pregleda slanja. Poslati smije samo označene zapise i cijeli odabrani transkript. Odbijanje privole ne radi mrežni zahtjev.
- U AI nacrtu promijenite projekt, vrstu, izvjesnost, osobu i rok; odznačite stavku. Samo označene potvrđene stavke ulaze u memoriju. Ponovite istu potvrdu: nema jednakih zapisa ponovno. Pregledajte točan citat i izvornu verziju.
- Iz novog diktata zabilježite promjenu odluke i povežite prethodnu odluku. Stari zapis ostaje u kronologiji. Upit o razvoju dogovora mora moći citirati oba izvora.
- Postavite pitanja iz specifikacije. Pregledajte dohvaćene izvore prije slanja, provjerite datume i poveznice. Kod nepovezanog pitanja mora jasno reći da podaci nedostaju, bez dopunjavanja općim znanjem.
- Izvezite `.officebackup`, prenesite u drugu testnu instalaciju i provjerite reprodukciju, sve verzije, memoriju i izvore. Ponovljeni uvoz ne prepisuje različitu audio datoteku. Pokušajte nevaljan paket, putanju `../`, simboličku vezu i sukob sadržaja; postojeće datoteke/baza ostaju sačuvane.
- Obrišite samo zvuk. Tekstovi, povijest i memorija ostaju; transkripcija zvuka više se ne nudi kao dostupna. JSON kopija bez audio datoteka mora biti jasno označena.
