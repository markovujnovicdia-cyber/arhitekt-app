# Provjera potpuno lokalnog Arhitekt Officea na iPhoneu16Pro

Ovo je protokol za izvršavanje, ne popis već provedenih mjerenja. Stvarno provedeni testovi navedeni su u REZULTATI.md i Native/TEST-RESULTS.md.

## Priprema

- Napravite prenosivu lokalnu kopiju postojećih podataka. Ugradite oba zaključana native XCFrameworka i instalirajte aplikaciju iz Xcodea na pravi iPhone16Pro. Simulator ne dokazuje A18Pro performanse.
- Lokalno uvezite višejezični Whisper small i Qwen3-1.7B Q4_K_M, uz usporedbu pouzdanog SHA-256. Provjerite odbijanje `.en`, drugog GGUF modela, oštećene datoteke i pogrešnog checksuma; prethodni valjani model mora ostati.
- Omogućite mikrofon. Uključite zrakoplovni način rada i isključite Wi-Fi. Nemojte unositi ni konfigurirati backend/API ključ: takav ekran ne postoji.
- Koristite vlastite lokalne hrvatske snimke/transkripte. Nije potrebno slati poslovni sadržaj u chat ili na server. Sintetički testni tekstovi u repozitoriju nisu označeni kao stvarni razgovori.

## Dugo snimanje i prekidi

1. Snimite odvojene sesije5,10,20 i30minuta. Uključite nazive projekata, vlastita imena, jasne i relativne rokove, odluke, planove i negacije. Preslušajte master i provjerite ukupno trajanje.
2. Pauzirajte i nastavite barem triput; preslušajte obje strane granice. Zaključajte iPhone5minuta tijekom snimanja i provjerite nastavak. Aplikacija ne smije automatski poslati ništa na mrežu.
3. Zasebno, bez zrakoplovnog načina, primite poziv ili odspojite Bluetooth mikrofon. Snimanje treba pauzirati uz poruku; nastavak je ručan. Ne očekujte snimku zvuka telefonskog poziva.
4. Prisilno zatvorite aplikaciju tijekom probnog snimanja, otvorite i provjerite oporavak iz dnevnika. Sačuvajte i nečitljivu djelomičnu datoteku. Izvorni PCM može sadržavati sve napisane okvire, ali zadnji hardverski buffer nije zajamčen nakon gašenja.
5. Odbijte mikrofon na svježoj instalaciji, zatim ga omogućite u Postavkama i ponovite. Isprobajte slabu raspoloživost prostora na testnom uređaju; pogreška ne smije zamijeniti staru snimku ili model.

## Lokalni Whisper i nastavak

1. U zrakoplovnom načinu pokrenite transkripciju. Provjerite napredak prozora, izvorni master i cjelovit konačni tekst.
2. Usporedite izgovoreno s tekstom na granicama svakog prozora. Stvarna ponavljanja ne smiju biti leksički izbrisana; prijelazne ponovljene riječi možete ručno ispraviti.
3. Prekinite nakon nekoliko dovršenih prozora, zatvorite i otvorite aplikaciju. „Nastavi” mora koristiti dovršene prozore iz dnevnika, bez ponavljanja početka. „Ponovno obradi” je odvojena namjerna radnja.
4. Promijenite model ili izvornu testnu snimku. Stari dnevnik ne smije biti primijenjen na drugi izvor/model. Prethodne verzije transkripta ostaju.
5. Ispravite dio transkripta i spremite novu reviziju. Citati ranijih potvrđenih informacija i dalje moraju otvoriti točan stari tekst.
6. Provjerite duži tihi dio: lokalni Whisper može vratiti prazno za tišinu; svaki izvorni prozor ipak ostaje pokriven. Ni tišina ni pogreška ne brišu master.

## Lokalni Qwen i kvaliteta značenja

1. Za svaku stvarnu snimku lokalno pripremite kontrolni popis važnih informacija prije analize: dogovor, odluka, otvoreno pitanje, osoba, zadatak, problem, promjena, rok, neizvjesnost. Usporedite prijedloge s tim popisom, ne samo s duljinom sažetka.
2. Analizirajte cijeli dugi tekst. Prekinite na sredini i nastavite s istim modelom/kontekstom; dovršeni validirani fragmenti moraju ostati u dnevniku. Promjena konteksta/modela stvara zaseban fingerprint.
3. Provjerite svaki doslovni citat i UTF-16 raspon, uključujući hrvatske znakove i emoji. Nejasan projekt traži ručni odabir. Izmišljeni ili dvosmisleni citat odbija se.
4. „Možda ćemo smanjiti garažu” ne smije postati potvrđena odluka. „U petak” bez dovoljno datuma ne smije sam stvoriti kalendarski rok. Osoba mora biti doslovno imenovana u dokazu. Lokalni nacrti počinju kao provizorni/neizvjesni.
5. Pregledajte i uredite vrstu, tekst, osobu, pouzdanost i rok. Samo označene potvrđene stavke spremaju se. Ponovite istu potvrdu i provjerite da nema identičnih zapisa ponovno.
6. Dodajte novu promjenu ranijeg dogovora i povežite je s prethodnom odlukom. Stari zapis mora ostati u kronologiji.
7. Ako odgovor dosegne granicu tokena ili krši JSON/shema/citat pravila, nema parcijalnih „potvrđenih” zaključaka. Izvor i raniji nacrti ostaju.

U rezultatima razlikujte ispravno izdvojene, propuštene i izmišljene tvrdnje. Sačuvan izvorni tekst ne dokazuje da je model razumio svaki detalj. Nije zadana izmišljena postotna točnost za hrvatski.

## FTS5 i razgovor

- Potražite pojam koji se pojavljuje tek pri kraju dugog transkripta. Poveznica mora voditi na original s odgovarajućim izvatkom i datumom.
- Provjerite Cerje/Cerju, garaža/garaže i tekst bez dijakritike. Prefiksi pomažu, ali nisu cjelovit morfološki ili embeddings model.
- Pitanja: „Što sam dogovorio s investitorom?”, „Koje probleme još nisam riješio?”, „Što se promijenilo?”, „Koje zadatke moram napraviti ovaj tjedan?”. Provjerite status stvarnih zadataka/problema i rokove, a ne stare tvrdnje iz izvornog transkripta.
- Pronađite i pregledajte lokalni kontekst, zatim tražite lokalni odgovor. Svaki ID izvora mora postojati i otvoriti izvor. Upit bez relevantnih podataka mora jasno reći da podaci nedostaju; nema mrežnog dopunjavanja.
- Uredite zapis, zatvorite problem ili uvezite stariju kopiju. Ponovite pretraživanje; indeks mora odražavati autoritativno stanje, bez zastarjelih rezultata.

## Memorija, temperatura i metrike

- Provjerite da dva velika modela ne mogu istodobno raditi. Uvoz/brisanje aktivnog modela onemogućeno je. Poslije svakog native poziva kontekst i težine se oslobađaju.
- U Mjerenjima zabilježite model/SHA, iOS verziju, trajanje zvuka, trajanje obrade, opaženi vrh RAM-a, stvarne LLM tokene/s i stanje temperature prije/poslije. Whisper nema LLM tokene/s.
- Upozorenje memorije i ozbiljno/kritično toplinsko stanje trebaju zaustaviti AI. Odlazak AI obrade u pozadinu treba prekinuti native rad i omogućiti nastavak; audio snimanje je odvojen tijek.
- Ponovite istu hrvatsku snimku sa small i optional medium te usporedite kvalitetu, vrijeme i opaženi RAM. Zabilježite i učitavanje modela; generationSeconds isključuje load/free, ukupno vrijeme ih uključuje.
- Sto-milisekundno uzorkovanje memorije daje opaženi vrh, ne dokaz apsolutnog maksimuma. iOS jetsam i hardverski prekid nije moguće u potpunosti spriječiti softverskim pragom.

## Pohrana i kopije

- Prije nadogradnje otvorite bazu ranije verzije s kopijom. Projekti, zadaci, faze, izvori i datumi moraju ostati sačuvani. Ne uključuje se CloudKit ili automatski mrežni backup aplikacijskog spremnika.
- Izvezite `.officebackup` na lokalno odredište, prenesite kabelom/AirDropom u drugu testnu instalaciju i obnovite. Provjerite master, sve revizije, lokalne prozore koji dijele master, checkpoint tekst, povijest i dokaze.
- Obrišite samo zvuk nakon prekida transkripcije. Sačuvani tekst kontrolne točke, prethodni transkripti i memorija moraju ostati. Potpuni paket mora zadržati i checkpoint-only sesiju.
- Ponovite uvoz, pokušajte različit sadržaj istog puta, nevaljan JSON, nedostajući master, prevelik paket i simboličku poveznicu. Postojeće datoteke i baza ne smiju se slijepo prepisati.
- Brisanje aplikacije uklanja lokalne podatke i modele. Provjerite ponovno pokretanje iPhonea uz prethodno potvrđene zapise, uključujući podatke nakon ručnih izmjena.
