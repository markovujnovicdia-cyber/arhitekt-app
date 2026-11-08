# Lokalni AI pogoni

AOWhisper poziva stvarni whisper.cpp; AOLlama poziva stvarni llama.cpp. Nema
mrežnog API-ja, API ključeva, HTTP poslužitelja ili mrežnog zamjenskog pogona.
Modeli su lokalne datoteke koje korisnik uvozi kroz aplikaciju.

## Izrada na Macu

Potrebni su puni Xcode s iOS SDK-om, Command Line Tools, Git, Python 3 i CMake
3.24 ili noviji. Na Macu instaliraj CMake, primjerice `brew install cmake`,
zatim iz korijena repozitorija pokreni:

```sh
tools/build-local-engines.sh --platform ios --jobs 4
```

Skripta dohvaća službene GitHub repozitorije na točnim revizijama iz
[upstream-lock.json](upstream-lock.json), provjerava reviziju i lokalne izmjene,
izrađuje dinamičke okvire za iOS arm64 i simulator arm64/x86_64 te ih spaja u:

- `Native/Artifacts/AOWhisper.xcframework`
- `Native/Artifacts/AOLlama.xcframework`

Skripta zatim ponovno generira Xcode projekt kako bi povezao nastale artefakte.

To su generirani artefakti i nisu uključeni u Git. Projekt Xcode mora oba
dinamička okvira povezati i ugraditi s opcijom **Embed & Sign**. Moduli za Swift
zovu se `AOWhisper` i `AOLlama`; javna sučelja su
[AOWhisper.h](Whisper/AOWhisper.h) i [AOLlama.h](Llama/AOLlama.h).

Ako artefakti već postoje, premjesti ih prije ponovne izrade. Izvori su u
`Native/.sources`, a međurezultati u `Native/.build`; obje putanje možeš promijeniti
argumentima `--source-cache` i `--build-root`. Nakon prvog dohvata izvorni kod i
predmemorija omogućuju izradu bez ponovnog pristupa mreži.

Na uređaju se koriste Apple Accelerate i Metal. Izvorni Metal shaderi ugrađuju
se u svaki okvir pomoću `GGML_METAL_EMBED_LIBRARY=ON`; nisu potrebne odvojene
datoteke iz razvojnog direktorija ni preuzimanje shadera. Metal lokalno priprema
shader pri pokretanju. RPC i dinamičko učitavanje pozadinskih pogona su isključeni.

## Razdvajanje dvaju GGML pogona

Upstream projekti sadrže različite verzije GGML-a. Stoga se ne povezuju kao dvije
statičke biblioteke u izvršnu datoteku aplikacije. Svaki AO okvir statički
uključuje vlastiti pogon, a njegov dinamički izvoz ograničen je na vlastita dva
simbola `ao_whisper_*` ili `ao_llama_*`. Preostali simboli, uključujući GGML,
privatni su okviru. Linux provjera učitava oba pogona istodobno i provjerava
popis izvezenih simbola pomoću `nm`.

## Pravila životnog vijeka i otkazivanja

Pozivi C su sinkroni; Swift ih izvršava izvan glavne dretve i zajedničkim redom
sprječava istodobno učitavanje Whisper i LLM modela. Svaki poziv učitava model i
stvara novi kontekst te ih oslobađa i pri uspjehu, pogrešci ili otkazivanju.
Globalna inicijalizacija LLM pozadinskog pogona ostaje do završetka procesa,
bez zadržavanja težina modela ili projektnih transkripata.

Whisper prima konačan mono PCM float32, 16 kHz, do 120 sekundi po prozoru. Aplikacija
šalje manje prozore i odvojeno trajno sprema granice, tekst i napredak. Rezultat je
JSON sa svakim segmentom i relativnim vremenima u sekundama. `initial_prompt`
prenosi prethodni tekst; decoder se ne dijeli između snimki. Izvorni audio i
checkpointe čuva aplikacijski sloj, pa prekid modela ne briše snimku.

LLM prima već formatiran Qwen3 ChatML prompt s `/no_think`. Generiranje je
determinističko i ograničeno JSON-object gramatikom iz upstream projekta.
Gramatika osigurava sintaksu; ne jamči istinitost, pokrivenost niti valjanost izvora.
Swift dodatno provjerava shemu, citate i potrebu ručne potvrde. Prompt koji ne
stane zajedno s traženim izlazom u kontekst vraća pogrešku; tekst se nikad tiho
ne odsijeca. Dosezanje granice izlaznih tokena vraća pogrešku i ne vraća djelomične
zaključke. Uspješan izlaz ima `stopReason: "eos"`.

Callback otkazivanja vraća broj različit od nule za prekid. Može se izvršiti na
radnoj dretvi pogona i mora biti thread safe, brz i bez iznimaka. Provjerava se
prije i nakon učitavanja, pri svakom LLM batchu i izlaznom tokenu te kroz abort
callback pogona. LLM dodatno prekida učitavanje kroz progress callback. GPU
operacija koja je već poslana Metalu može završiti prije primjene prekida; ovo
nije trenutačan hardverski prekid. Na Whisper inicijalizaciju modela abort
callback se ne primjenjuje. Izvorni audio ostaje spremljen tijekom čekanja.

Povratni statusi su 0 uspjeh, 1 pogreška, 2 otkazivanje. Alocirani JSON rezultat
oslobađa samo odgovarajući `ao_*_free_text`. C++ iznimke ne prelaze C sučelje.
Tekstovi, putanje i sadržaj modela ne ispisuju se kroz engine logger.

`generatedTokens` broji emitirane tokene bez završnog EOS tokena.
`generationSeconds` mjeri prefill i autoregresivno generiranje; ne uključuje
učitavanje modela, stvaranje konteksta ni oslobađanje. Vrijeme cijelog poziva,
memoriju i termalno stanje zasebno mjeri aplikacija.

## Provjera na Linuxu

```sh
tools/build-local-engines.sh --platform linux --jobs 4
```

Ovo stvarno kompilira oba upstream CPU pogona i C++ sučelja, provjerava UTF-8/JSON
escaping, stvarno parsiranje i prihvaćanje/odbijanje teksta JSON gramatikom te
pokreće testove učitavanja oba modula, privatnosti simbola, pogrešaka,
nevaljanog zvuka, otkazivanja i granica izlaznog spremnika. Dva modelna testa
preskaču se dok im izričito ne navedeš lokalne modele i hrvatsku snimku:

```sh
python3 Native/Tests/test_bridges.py \
  --whisper-model /putanja/ggml-small.bin \
  --wav /putanja/hrvatski-16k-mono.wav \
  --llama-model /putanja/Qwen3-1.7B-Q4_K_M.gguf
```

Modelni testovi ne preuzimaju datoteke. Kratka smoke provjera nije mjerenje
točnosti na dugim hrvatskim transkriptima. Kompilacija Linux pogona također nije
potvrda kompilacije za iOS niti test na iPhoneu. iOS izradu, performanse,
temperaturu, stvarno diktiranje dulje od 20 minuta i kvalitetu Qwen3 1.7B treba
zasebno potvrditi na ciljnom uređaju prije uporabe s poslovnim zapisima.

Licence upstream izvora nalaze se u [licenses](licenses/). Revidiraj lock i oba
izvoza te ponovi sve provjere pri svakoj promjeni upstream revizije.
