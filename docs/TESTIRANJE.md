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
