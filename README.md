# Indexa

Natywna aplikacja paska menu macOS łącząca prywatną rozmowę Matrix/Element X, profil Hermes `indexa` i kontrolowany dostęp do Notatek, Przypomnień i Kalendarza. Swift obsługuje aplikację i kolejkę; lokalny Python — transport Matrix i usługi; Rust — logowanie QR. Bez kontenera i bez przechowywania sekretów w Keychain.

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

Testy Matrix wymagają Pythona 3.11 z `matrix/requirements.txt`. Testy `test_matrix_media.py`, `test_matrix_journal.py`, `test_matrix_qr_boundaries.py`, `test_bot_identity.py`, `test_matrix_crypto.py` i `test_matrix_setup.py` działają na danych tymczasowych. Testy z `live` w nazwie korzystają z prawdziwej instalacji i nie są wykonywane automatycznie w CI.

## Dane i bezpieczeństwo

Dane aplikacji są w `~/Library/Application Support/Indexa`, a profil agenta w `~/.hermes/profiles/indexa`. Losowy klucz lokalny odblokowuje szyfrowany sejf. Ochrona uprawnień plików nie izoluje aplikacji działających jako ten sam użytkownik macOS. Nie publikuj katalogu danych ani kluczy podpisywania.

Tailscale zapewnia prywatny transport. Indexa nie potrzebuje zmian w służbowym VPN. Ustawienia retencji kolejki Indexy nie oznaczają usuwania historii z baz Matrix i Hermesa.

## Własne narzędzia MCP

Każda integracja ma jedną kartę z przełącznikiem i statusem. Uprawnienia są pod „Dostęp i szczegóły”, historia i konfiguracja techniczna są zwinięte. Stały pasek na dole okna pokazuje Hermes, Tailscale i Matrix na każdej zakładce; kliknięcie statusu otwiera szczegóły. Błąd ostatniej operacji jest widoczny na karcie, z bezpiecznym opisem bez treści użytkownika.

Zakładka **Integracje → Apple Notes** udostępnia `notes_get`, `notes_create` i `notes_append`. Moduł oraz odczyt, tworzenie i dopisywanie mają osobne przełączniki; domyślnie wszystkie są wyłączone. Włączenie zapisu jest zgodą na wykonywanie poleceń agenta bez potwierdzania każdej notatki. Dostęp dotyczy wyłącznie folderu Indexa w domyślnym koncie Notatek, bez usuwania. Pierwsze użycie może wymagać systemowej zgody na automatyzację Notatek.

**Kalendarz** korzysta z natywnego EventKit: `calendar_lists`, `calendar_events`, `calendar_create`. Odczyt obejmuje wszystkie istniejące kalendarze, również tylko do odczytu; można zawęzić go identyfikatorem kalendarza. Wymagany zakres dat do 366 dni. Wyniki są stronicowane (domyślnie 20, maksymalnie 50); `next_offset` wskazuje kolejną stronę. Filtr przeszukuje tytuł, miejsce i opis, ale pełne opisy są zwracane tylko z `include_notes=true`. Każde wystąpienie cykliczne ma własne `occurrence_id`. Odczyt EventKit nie gwarantuje obecności niezapisanych sugestii widocznych w interfejsie Kalendarza. Tworzenie wydarzeń ma oddzielne uprawnienie; domyślnie używa systemowego kalendarza albo wskazanego zapisywalnego kalendarza. Obsługuje miejsce, opis i alert przed wydarzeniem; bez zaproszeń i usuwania.

**Przypomnienia**: `reminders_lists`, `reminders_list`, `reminders_create`, `reminders_complete`. Odczyt dotyczy istniejących list, domyślnie nieukończonych wpisów; tworzenie i oznaczanie jako wykonane mają osobne zgody. Termin może zawierać powiadomienie. Nowe moduły i ich uprawnienia są domyślnie wyłączone. Systemową zgodę EventKit użytkownik nadaje w karcie integracji; macOS udziela aplikacji pełnego dostępu, a przełączniki MCP ograniczają narzędzia agenta. Odmowa lub cofnięcie zgody pojawia się w statusie.

Zapisy EventKit wymagają UUID `operation_id`. Trwały rejestr w bazie Indexy przechowuje skrót żądania i identyfikator wyniku, bez tytułów i opisów. Ten sam zapis nie jest wykonywany ponownie; niepewnego wyniku nie wolno ponawiać z nowym ID. `verified=true` potwierdza lokalny zapis i odczyt zwrotny, nie synchronizację z iPhonem. Alerty Kalendarza i Przypomnień nie są budzikami aplikacji Zegar.

MCP słucha tylko na `127.0.0.1:43121`; endpointy to `/mcp/notes`, `/mcp/calendar`, `/mcp/reminders` i `/mcp/files`, z oddzielnymi sesjami. Transport negocjuje MCP Streamable HTTP w wersjach 2025-03-26, 2025-06-18 lub 2025-11-25. Powiadomienia `tools/list_changed` aktualizują listę narzędzi; także wywołanie wcześniej zapamiętanego narzędzia ponownie sprawdza uprawnienia. Wyłączenie nie cofa już rozpoczętej operacji. Zamknięcie aplikacji czeka na zakończenie wywołań.

Indexa automatycznie podłącza MCP do istniejącego profilu `indexa` w Hermesie przy starcie i po zmianie tokena, używając mechanizmu zapisu jego CLI. **Integracje → Ustawienia zaawansowane MCP** pokazują wynik rzeczywistego testu połączenia i pozwalają ponowić konfigurację. Model i pozostałe serwery MCP pozostają bez zmian. W `SOUL.md` Indexa utrzymuje własną oznaczoną sekcję krótkich, naturalnych odpowiedzi; zachowuje pozostałą personę oraz kopię sprzed pierwszej zmiany. Po zmianie katalogu narzędzi lub persony odświeża zapisany schemat narzędzi i prompt wspólnego czatu bez usuwania historii. Stary plugin `indexa-notes` jest wyłączany, a jego wybór narzędzi migrowany do MCP; otwarte wcześniej procesy Hermesa z tym pluginem wymagają ponownego uruchomienia.

Profil `indexa` używa `tools.tool_search.enabled: "off"`: narzędzia trafiają bezpośrednio do agenta. Omija to zachowywany przez Hermesa stary opis katalogu `tool_search` we wspólnej rozmowie, bez kasowania jej historii.

Podczas zadań przekazywanych przez Indexę Matrix pokazuje wskaźnik „pisze…”. Jest odnawiany co 10 sekund i wygaszany po zakończeniu, błędzie lub oczekiwaniu na zgodę. Po awarii wygasa sam po 25 sekundach; niedostępność wskaźnika nie blokuje wiadomości. Nie obejmuje zadań rozpoczętych bezpośrednio w desktopowym Hermesie.

Token 256-bitowy znajduje się w oddzielnym sejfie `mcp-secrets.vault`, bez Keychain. Hermes otrzymuje kopię w swoim `.env` (0600), a konfiguracja wskazuje `Bearer ${INDEXA_MCP_TOKEN}`. Rotacja zamyka sesje i unieważnia poprzedni token. Tylko inne klienty MCP wymagają ręcznej aktualizacji: ustawienia zaawansowane pozwalają skopiować konfigurację z tokenem i czyszczą niezmieniony schowek po minucie. Cofanie uprawnień dotyczy narzędzi MCP Indexy, nie innych narzędzi niezależnie udostępnionych Hermesowi.

Notes MCP korzysta z dotychczasowego rejestru operacji: nowy zapis wymaga UUID `operation_id`, ponowienie tego samego zapisu tego samego UUID. Niepewny wynik blokuje dalsze zapisy do ręcznego sprawdzenia. Historia w panelu MCP obejmuje ostatnie 512 wywołań od startu serwera, bez treści notatek i argumentów. HomeKit jest odłożony; aplikacja nie publikuje atrap narzędzi Home.

Zwykłe testy Swift obejmują uwierzytelnianie, sesje, SSE, cofanie uprawnień, rotację i zakończenie aktywnej operacji. Aby dodatkowo sprawdzić rzeczywisty klient MCP Hermesa, uruchom `MCP_TEST_PYTHON=/ścieżka/do/python-z-mcp bash scripts/test-local.sh`. Test używa syntetycznego modułu na porcie 43129 i nie dotyka Notatek.

## Załączniki i statusy Matrix

Prywatny, szyfrowany pokój właściciela przyjmuje zdjęcia i pliki do 20 MiB. Obrazy są zmniejszane do 2048 px i przekazywane modelowi obsługującemu obraz. Dokumenty: tekst UTF-8 do 200 KB lub PDF z warstwą tekstową do 100 stron / 200 KB tekstu. Skany PDF wymagają OCR poza Indexą; audio i wideo są na razie odrzucane czytelną odpowiedzią. Odczyt potwierdza trwałe przyjęcie wiadomości. Reakcje pokazują przyjęcie, pracę, oczekiwanie na zgodę oraz wynik zadania; problemy z reakcjami nie blokują rozmowy.

**Pliki i raporty** udostępnia `files_create`: tworzenie TXT, MD, CSV, JSON i prostego PDF z tekstu do 100 KB. Moduł jest włączany raz przy migracji; potem respektuje przełączniki użytkownika. Zapisuje tylko w katalogu eksportów Indexy, bez dostępu do innych plików. Zwrócony `MEDIA:<path>` w osobnym wierszu odpowiedzi zamienia się w szyfrowany załącznik Matrix. Ponowienia używają tego samego `operation_id`; zmieniony eksport jest odrzucany. Wysyłka ma trwały identyfikator zapobiegający duplikatom.

Lokalne kopie załączników podlegają retencji treści, z zachowaniem plików aktywnych zadań i niedostarczonych odpowiedzi. Nie usuwa to kopii Matrix ani historii Hermesa. Głosówki i rozmowy na żywo nie są częścią tej wersji.

## Aktualizacje

Sparkle 2.9.2 sprawdza podpisane archiwa z GitHub Releases. Publiczny kanał nie wymaga logowania. W menu lub Ustawieniach wybierz „Sprawdź aktualizacje…”, potem instalację i ponowne uruchomienie; Sparkle wymienia aplikację i uruchamia ją ponownie po zakończeniu usług. Token GitHub nie trafia do aplikacji.

Procedura wydania, zakres aktualizacji i odzyskiwanie: [docs/RELEASE.md](docs/RELEASE.md).

Aplikacja jest instalowana w `/Applications/Indexa.app`. `python3 scripts/install-app.py` przenosi poprzednią kopię z `~/Applications`, odmawia instalacji podczas aktywnego zadania, sprawdza podpis i uruchamia aplikację. Dane pozostają w katalogu użytkownika. Kolejne wydania publikuj jako GitHub Release z podpisanym `appcast.xml`; samo wypchnięcie kodu nie udostępnia aktualizacji.

Od 0.5.3 budowanie wymaga istniejącego klucza podpisu `.signing/key.pem` (0600) i publicznego certyfikatu z repozytorium. Brak klucza blokuje wydanie, zamiast zmieniać tożsamość aplikacji i tracić zgody macOS. Podpisywanie nie używa Keychain. Szczegóły w [procedurze wydania](docs/RELEASE.md#stała-tożsamość-aplikacji-od-053).
