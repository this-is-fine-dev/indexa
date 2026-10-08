# Indexa

Natywna aplikacja paska menu macOS łącząca prywatną rozmowę Matrix/Element X, profil Hermes `indexa` i kontrolowany dostęp do Apple Notes. Swift obsługuje aplikację i kolejkę; lokalny Python — transport Matrix i usługi; Rust — logowanie QR. Bez kontenera i bez przechowywania sekretów w Keychain.

## Stan projektu

Działa na skonfigurowanym Macu z Apple Silicon i macOS 14+. Repozytorium zawiera kod aplikacji, testy i publikowanie aktualizacji. Archiwum aplikacji **nie jest jeszcze instalatorem kompletnego środowiska na nowym Macu**: wymaga istniejącego profilu Hermes, kont Matrix oraz natywnego runtime. Skrypty `configure-matrix*` i `setup_qr.py` służyły pierwszej konfiguracji; nie uruchamiaj ich jako aktualizacji używanej instalacji.

## Budowanie i testy

```sh
# Pierwszy build natywnych komponentów; wymaga narzędzi Xcode i Rust.
bash scripts/build-matrix-qr.sh
bash scripts/test-local.sh
python3 -B Tests/test_notes.py
python3 -B Tests/test_runtime_update.py
bash scripts/build-app.sh
```

Wynik: `dist/Indexa.app` i `dist/Indexa-<wersja>.zip`. Wersja pochodzi z `release/version.txt`, a w CI z tagu `vX.Y.Z`. Brak binarnego pomocnika QR zatrzymuje pakowanie.

Testy Matrix wymagają Pythona 3.11 z `matrix/requirements.txt`. Testy `test_matrix_journal.py`, `test_matrix_qr_boundaries.py`, `test_bot_identity.py`, `test_matrix_crypto.py` i `test_matrix_setup.py` działają na danych tymczasowych. Testy z `live` w nazwie korzystają z prawdziwej instalacji i nie są wykonywane automatycznie w CI.

## Dane i bezpieczeństwo

Dane aplikacji są w `~/Library/Application Support/Indexa`, a profil agenta w `~/.hermes/profiles/indexa`. Losowy klucz lokalny odblokowuje szyfrowany sejf. Ochrona uprawnień plików nie izoluje aplikacji działających jako ten sam użytkownik macOS. Nie publikuj katalogu danych ani kluczy podpisywania.

Tailscale zapewnia prywatny transport. Indexa nie potrzebuje zmian w służbowym VPN. Ustawienia retencji kolejki Indexy nie oznaczają usuwania historii z baz Matrix i Hermesa.

## Własne narzędzia MCP

Zakładka **Integracje → Apple Notes** udostępnia `notes_get`, `notes_create` i `notes_append`. Moduł oraz odczyt, tworzenie i dopisywanie mają osobne przełączniki; domyślnie wszystkie są wyłączone. Włączenie zapisu jest zgodą na wykonywanie poleceń agenta bez potwierdzania każdej notatki. Dostęp dotyczy wyłącznie folderu Indexa w domyślnym koncie Notatek, bez usuwania. Pierwsze użycie może wymagać systemowej zgody na automatyzację Notatek.

MCP słucha tylko na `127.0.0.1:43121`; Notes ma endpoint `/mcp/notes`. Każdy kolejny moduł otrzyma oddzielny endpoint i sesje. Transport negocjuje MCP Streamable HTTP w wersjach 2025-03-26, 2025-06-18 lub 2025-11-25. Powiadomienia `tools/list_changed` aktualizują listę narzędzi; także wywołanie wcześniej zapamiętanego narzędzia ponownie sprawdza uprawnienia. Wyłączenie nie cofa już rozpoczętej operacji. Zamknięcie aplikacji czeka na zakończenie wywołań.

Token 256-bitowy znajduje się w oddzielnym sejfie `mcp-secrets.vault`, bez Keychain. „Kopiuj konfigurację dla Hermesa” kopiuje także token i czyści niezmieniony schowek po minucie. Rotacja zamyka sesje i unieważnia poprzedni token; następnie trzeba zaktualizować konfigurację klientów. W Hermesie sekret powinien trafić do `.env` (0600), a nagłówek konfiguracji wskazywać `Bearer ${INDEXA_MCP_TOKEN}`. Stary plugin `indexa-notes` należy wyłączyć przez CLI Hermesa i przeładować działające procesy; pozostawienie go włączonego daje osobną drogę do notatek poza MCP. Nie dotyczy to innych narzędzi, które użytkownik niezależnie udostępnił Hermesowi.

Notes MCP korzysta z dotychczasowego rejestru operacji: nowy zapis wymaga UUID `operation_id`, ponowienie tego samego zapisu tego samego UUID. Niepewny wynik blokuje dalsze zapisy do ręcznego sprawdzenia. Historia w panelu MCP obejmuje ostatnie 512 wywołań od startu serwera, bez treści notatek i argumentów. HomeKit jest odłożony; aplikacja nie publikuje atrap narzędzi Home.

Zwykłe testy Swift obejmują uwierzytelnianie, sesje, SSE, cofanie uprawnień, rotację i zakończenie aktywnej operacji. Aby dodatkowo sprawdzić rzeczywisty klient MCP Hermesa, uruchom `MCP_TEST_PYTHON=/ścieżka/do/python-z-mcp bash scripts/test-local.sh`. Test używa syntetycznego modułu na porcie 43129 i nie dotyka Notatek.

## Aktualizacje

Sparkle 2.9.2 sprawdza podpisane archiwa z GitHub Releases. Kanał jest przygotowany pod publiczne repozytorium; dopóki repozytorium pozostaje prywatne, pobieranie aktualizacji bez logowania nie zadziała. Token GitHub nie trafia do aplikacji.

Procedura wydania, zakres aktualizacji i odzyskiwanie: [docs/RELEASE.md](docs/RELEASE.md).
