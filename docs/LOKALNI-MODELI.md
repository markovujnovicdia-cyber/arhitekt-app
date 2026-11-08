# Lokalni modeli za iPhone16Pro

Težine modela nisu ugrađene u repozitorij i aplikacija ih ne preuzima. Preuzmite ih na vlastitom računalu i prenesite na iPhone kabelom ili AirDropom. Nakon uvoza transkripcija, analiza i upiti mogu se provjeriti u zrakoplovnom načinu rada. Preuzimanje izvora/modela za pripremu nije slanje poslovnih podataka.

## Whisper small — početni model

Koristite **višejezični** whisper.cpp `ggml-small.bin`, ne `small.en`, ne PyTorch `.pt` i ne arhivu.

- [Službeni whisper.cpp projekt](https://github.com/ggml-org/whisper.cpp)
- [Repozitorij modela na koji upućuje zaključana upstream skripta](https://huggingface.co/ggerganov/whisper.cpp)
- [ggml-small.bin](https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin)

Na računalu, ako želite naredbu umjesto preglednika:

```sh
curl --fail --location --output ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
shasum -a 256 ggml-small.bin
```

Ostavite TLS provjeru uključenu. Provjerite SHA-256 prema LFS metapodatku iste datoteke/revizije u pouzdanom repozitoriju prije prijenosa. Sama lokalno izračunata vrijednost bez usporedbe nije dokaz izvornosti.

## Whisper medium — opcija

Preuzmite `ggml-medium.bin` iz istog repozitorija. Ne `medium.en`. Model je veći; počnite sa small i usporedite stvarnu hrvatsku snimku, vrijeme i opaženi RAM prije promjene. Aplikacija ne prebacuje se na medium sama pri pogrešci.

## Qwen3 1.7B — analiza i razgovor

Koristite točno **Qwen3-1.7B u GGUF Q4_K_M** formatu.

- [Službeni Qwen3 projekt](https://github.com/QwenLM/Qwen3)
- [Qwen3-1.7B GGUF model](https://huggingface.co/Qwen/Qwen3-1.7B-GGUF)
- Odaberite `Qwen3-1.7B-Q4_K_M.gguf` među datotekama te provjerite model card, licencu i LFS SHA-256.

```sh
curl --fail --location --output Qwen3-1.7B-Q4_K_M.gguf \
  https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf
shasum -a 256 Qwen3-1.7B-Q4_K_M.gguf
```

Ako se naziv datoteke/revizija u službenom repozitoriju promijeni, pregledajte Files stranicu i koristite točnu Q4_K_M datoteku umjesto zaobilaženja validacije. Datoteke modela mijenjaju se neovisno o ovom projektu; njihove trenutne težine/sažeci nisu preuzeti ni potvrđeni u razvojnom okruženju jer je Hugging Face blokiran mrežnom politikom. Nisu umetnuti izmišljeni checksumovi.

Aplikacija provjerava GGUF arhitekturu `qwen3`,28blokova,2048dimenzija,6144FFN,16glava,8KVglava,151936tokena i file_type15(Q4_K_M). To su očekivana svojstva ovog modela, ne oznaka izvedena iz imena. Imena datoteka i samo GGUF magic nisu dovoljni za prihvat.

## Uvoz u aplikaciji

1. Najprije izradite i povežite oba native XCFrameworka na Macu prema korijenskom README-u.
2. Na iPhoneu otvorite **zupčanik → Lokalni AI modeli i izvođenje**.
3. Odaberite ulogu modela: Whisper small, neobvezni medium ili Qwen3.
4. Odaberite datoteku iz lokalnih Datoteka. Ako imate pouzdani SHA-256, unesite ga u neobvezno polje. Ne unosite API ključ: aplikacija ga nema niti treba.
5. Pričekajte kopiranje i provjeru. Neuspješan uvoz ne zamjenjuje stari valjani model. Aplikacija računa i čuva SHA čak i bez očekivane vrijednosti, ali to označava kao usporedbom nepotvrđeno.
6. Kao Whisper izbor zadržite small. Prvo testirajte kratku vlastitu snimku i pogledajte metrike. Tek onda testirajte20minuta i medium.

Uvoz radi asinkrono uz ograničene spremnike. Native model loading provjerava stvarne tenzore; zaglavlje samo po sebi ne jamči neoštećene težine. Zamjena/brisanje modela onemogućeno je tijekom aktivne inferencije. Modeli nisu dio korisničke sigurnosne kopije; nakon obnove aplikacije uvezite ih ponovno.

Za vlastite povjerljive testove zadržite zvuk i tekst na uređaju. Ne treba ih slati u chat ili na server. Kvalitetu semantičke ekstrakcije usporedite s vlastitim izvorom prije poslovne uporabe; Qwen1.7B može propustiti ili pogrešno protumačiti detalje i svaka potvrda ostaje ručna.
