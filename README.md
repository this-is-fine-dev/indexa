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

## Aktualizacje

Sparkle 2.9.2 sprawdza podpisane archiwa z GitHub Releases. Kanał jest przygotowany pod publiczne repozytorium; dopóki repozytorium pozostaje prywatne, pobieranie aktualizacji bez logowania nie zadziała. Token GitHub nie trafia do aplikacji.

Procedura wydania, zakres aktualizacji i odzyskiwanie: [docs/RELEASE.md](docs/RELEASE.md).
