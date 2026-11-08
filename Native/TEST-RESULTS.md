# Stvarno provedene provjere

Datum: 2026-11-08. Okruženje: Linux x86_64, GCC 14.2.0, Python 3.12.14,
CMake 4.4.4. Izvori: točne dvije revizije iz `upstream-lock.json`.

Pokrenuto je `tools/build-local-engines.sh --platform linux --jobs 4`.

- Stvarni upstream Whisper CPU pogon, GGML i AOWhisper C++ sučelje: kompilacija
  i dinamičko povezivanje uspješni.
- Stvarni upstream Llama CPU pogon, GGML i AOLlama C++ sučelje: kompilacija i
  dinamičko povezivanje uspješni.
- C++ provjera JSON escaping: prošla, uključujući hrvatske znakove, emoji,
  kontrolne znakove i nevaljan/nepotpun UTF-8. Assertions su omogućeni i u Releaseu.
- C++ provjera stvarnom upstream JSON gramatikom: prošla. Prihvaćen je hrvatski
  ugniježđeni JSON; odbijeni su dodatni tekst, think tagovi, nepotpun JSON,
  višestruki korijenski objekti, nevaljani brojevi i pogrešan korijenski tip.
- Python C-ABI provjere: 7 prošlo. Oba pogona učitana su istodobno; potvrđena je
  izvozna izolacija, ponašanje bez modela, nevaljan GGUF, nevaljan zvuk,
  otkazivanje, nevaljan kontekst i završetak jednog bajta error spremnika.
- `nm -D --defined-only`: svaki okvir izvozi samo svoje dvije funkcije `ao_*`.
- Shell sintaksa skripte: prošla.

Preskočene su 2 modelne provjere jer nisu bili dostupni lokalni Whisper model,
hrvatska snimka i Qwen3 GGUF. Dohvat konfiguracije s Hugging Facea blokiran je
pravilima mreže okruženja; nisu korišteni zamjenski izvori za zaobilaženje blokade.

Nisu provedeni iOS/Xcode/Metal kompilacija, pokretanje na iPhoneu, mjerenje
RAM-a ili temperature na uređaju, stvarna transkripcija ni Qwen3 inference.
Točnost, brzina i očuvanje značenja dugih hrvatskih diktata nisu ovim provjerama
potvrđeni. Mac skripta i sučelje pripremljeni su za te naredne provjere.
