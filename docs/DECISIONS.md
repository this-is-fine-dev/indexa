# Indexa — decyzje i discovery, 2026-10-07

## Pomiary opóźnień i odbiór Matrix — 2026-10-08, 0.5.8

Lokalny `/events` czeka do 10 s na nowe zdarzenie i wraca od razu po trwałym zapisie odszyfrowanej wiadomości właściciela. To czas maksymalnego oczekiwania pustego odbiornika, nie opóźnienie wiadomości. Zniesiono 2-sekundową przerwę między odbiorami; niegotowa usługa nadal ma przerwę i backoff. Odebrana wiadomość wywołuje obsługę Hermesa od razu. Nowa odpowiedź budzi niezależne zadanie wysyłki, zachowując okresowe ponowienia, FIFO, deduplikację i anulowanie przy wyłączeniu. Oczekiwanie na Matrix nie blokuje pracy Hermesa.

`bridge.sqlite/latency_events` przechowuje znaczniki UTC, skorelowany UUID zadania, etap, czas trwania i kod wyniku. Etapy obejmują przyjęcie, wiek znacznika źródłowego, przygotowanie/submit, czas wykonania raportowany przez Hermesa, powolne lub końcowe sprawdzenia statusu, powolne odczyty historii, dopasowanie odpowiedzi oraz osobno wysyłkę transkrypcji i odpowiedzi. Kod 200 oznacza udany etap; nie zawsze jest oryginalnym kodem HTTP. Czasy lokalnych operacji używają zegara monotonicznego. `upstream_age` jest różnicą zegarów źródła i odbiornika: dla Pebble obejmuje nagranie/transkrypcję, nie sam transfer. Czas Hermesa obejmuje model i narzędzia; potwierdzenie wysyłki Matrix oznacza przyjęcie przez serwer, nie wyświetlenie na iPhonie.

Bez treści, sekretów, argumentów narzędzi, URL-i i odpowiedzi błędów. Nieznane identyfikatory są haszowane; późniejsze powiązanie odpowiedzi Hermesa scala identyfikatory. Limit: 7 dni / 10000 wpisów, eksport w Diagnostyce zawiera ostatnie 200. Zapis metryk nie czeka na blokadę bazy i nie przerywa zadań po błędzie. Nie odtwarzamy fikcyjnych pomiarów dawnych zadań.

Walidacja: test pustego inboxa najpierw odtworzył brak oczekiwania, potem potwierdził natychmiastowe obudzenie, backlog, ACK, timeout i anulowanie. Testy metryk sprawdzają trwałość, korelację, brak treści, limity i awarię/blokadę dziennika. Dotychczasowe 46 testów Swift oraz 3 nowe testy metryk i testy Python transportu/mediów/granic QR zaliczone. Nowe rzeczywiste czasy będą zbierane po instalacji; stare próbki Matrix z wcześniejszej wersji nie są benchmarkiem tego wydania. Bez zmiany modelu, ustawień reasoning, VPN i DNS.

## Transkrypcje Pebble w Matrixie — 2026-10-08, 0.5.7

Rzeczywiste nagranie Pebble zapisuje teraz wiadomość „🎙️ Z pierścienia” z transkrypcją w tej samej transakcji co przyjęcie zadania. Wykorzystuje istniejący szyfrowany transport bota i trwały outbox: ponowienie webhooka/restart nie dublują wiadomości, a FIFO umieszcza ją przed odpowiedzią. To wiadomość bota oznaczająca polecenie z pierścienia, nie podszywanie się pod konto użytkownika. Testy połączenia i wiadomości przychodzące z Matrixa nie tworzą echa. Dla nagrania odebranego przed sparowaniem pokoju worker dodaje transkrypcję przy podjęciu zadania. Nie odtwarzamy starych zakończonych nagrań.

Pomiar ostatniego rzeczywistego nagrania: recorded_at → received_at 12,252 s (obejmuje nagranie i przetwarzanie po stronie Pebble), odbiór → przekazanie do Hermesa 0,603 s, przekazanie → zakończenie 10,227 s. To pojedynczy pomiar, nie benchmark. Skrócono odstęp sprawdzania Hermesa i wysyłki z 2 do 1 s; model i jego ustawienia pozostają bez zmian. Testy odtworzyły brak echa, następnie sprawdziły treść, kolejność, brak duplikatów po restarcie i wykluczenie testów/Matrixa. 46 testów Swift zaliczonych (opcjonalny SDK pominięty).

## Pebble Hold & Talk — 2026-10-08, 0.5.6

Odbiornik odrzucał podpisane `single-click-hold` kodem 422 `unsupported_trigger`, choć weryfikacja podpisu obsługiwała ten gest. Test połączenia (`test-event`) przechodził, co maskowało błąd. Screen użytkownika z Recent runs potwierdził 422 dla nagrań i 202 dla testów. Ingress akceptuje teraz oba gesty nagrania; zachowane są podpisy, rozróżnienie testów i deduplikacja. Instrukcja w aplikacji opisuje osobną konfigurację każdego gestu.

Test regresji najpierw odtworzył 422, następnie przeszedł dla obu podpisanych gestów, duplikatów, testu bez zadania i zmienionego nagłówka odrzucanego jako 401. Pełny zestaw Swift: 45 testów zaliczonych (opcjonalny test SDK pominięty). Zainstalowano i ponownie uruchomiono 0.5.6 w `/Applications`; odbiornik i Matrix zwracają 200. Użytkownik potwierdził odpowiedź w Element X po zwykłym przytrzymaniu; lokalny wpis Pebble i zadanie mają stan `completed`, bez błędu. Bez zmian VPN/DNS/Tailscale.

## Pebble przez istniejące HTTPS Matrixa — 2026-10-08

Webhook używa `https://<host>.ts.net:8443/pebble/v1/ingest`, czyli istniejącego prywatnego Serve Matrixa → `127.0.0.1:18763`. Proxy przyjmuje tylko dokładny POST tej ścieżki i kieruje go do portu odbiornika przekazanego przez Indexę w `INDEXA_PEBBLE_PORT`. Surowe bajty i nagłówki podpisu trafiają do dotychczasowej weryfikacji HMAC; limit webhooka wynosi 20 MiB. Endpointy administracyjne i health pozostają niedostępne przez proxy. Pozostałe ścieżki Matrixa nie zmieniają celu.

Z aplikacji usunięto zapisujące API Tailscale i przyciski włączania Serve. Indexa odczytuje istniejącą konfigurację, a adres webhooka pokazuje tylko dla prywatnego HTTPS 8443 prowadzącego do jej proxy. Zmiana nie wymaga nowego portu, zmiany konfiguracji Tailscale, DNS, tras ani służbowego OpenVPN. Po aktualizacji należy skopiować nowy adres do Pebble; sekret i opcja Sign requests pozostają te same.

Walidacja po instalacji 0.5.5: podpisany test przez HTTPS 8443 → 202, powtórzenie → deduplikacja, zmodyfikowana treść → 401, endpoint wersji Matrixa → 200. Konfiguracja Serve, DNS, brama domyślna i procesy OpenVPN były identyczne przed instalacją i po niej. Test z fizycznego iPhone'a wymaga podmiany adresu w Pebble przez użytkownika.

## Istniejąca rozmowa Matrix jako Bot Chat w Hermes Desktop

Widok BOTS otwierał pustą sesję desktopową, podczas gdy historia Matrixa znajdowała się w osobnej sesji API. `scripts/link-hermes-bot-chat.py` powiązał bieżący identyfikator rozmowy bridge z natywnym rejestrem Hermesa (dokładny tytuł `Bot Chat`, hidden=1). Pustą wcześniejszą sesję zachowano jako archiwalną; zmiana metadanych jest transakcyjna i odmawia zastąpienia czatu zawierającego wiadomości. Kopia sprzed zmiany: `~/.hermes/profiles/indexa/before-indexa-bot-chat.sqlite` (0600). Nie zmieniano kodu Hermesa ani treści wiadomości.

Walidacja: skrypt bez `--apply` najpierw zgłaszał różne sesje, po migracji PASS; hash wszystkich wierszy messages nie zmienił się. CUA potwierdziło BOTS → inny bot → Indexa: zakładka INDEXA, dokładny identyfikator rozmowy bridge i dotychczasowa historia. Nie wysyłano dodatkowych wiadomości testowych. Jest to podłączenie bieżącej rozmowy; obecne jawne `!new` / „Nowa rozmowa” w Indexie nadal tworzy oddzielną sesję. Wiadomości wysłane bezpośrednio z Desktop nie są automatycznie kopiowane do pokoju Matrix przez outbox Indexy.

## Weryfikacja tożsamości bota po udanym logowaniu telefonu

Użytkownik potwierdził logowanie QR i działającą rozmowę w Element X. Ostrzeżenie o niezweryfikowanym urządzeniu nadawcy miało osobną przyczynę: bot nie posiadał kluczy cross-signing w Synapse. Dodano trwałą tożsamość bota wyprowadzoną przez HKDF z losowego sekretu w istniejącym szyfrowanym sejfie. Biblioteki signedjson/PyNaCl podpisują istniejące urządzenie INDEXA_BOT po sprawdzeniu jego własnego podpisu i zgodności klucza z lokalnym magazynem nio. Istniejąca tożsamość właściciela podpisuje tożsamość bota przez Matrix Rust SDK; inny istniejący klucz główny jest odrzucany. Bez resetu kont, telefonu, pokoju lub historii, bez Keychain i zmian VPN.

Sprawdzenie: test_bot_identity.py PASS; rzeczywisty serwer potwierdził podpis urządzenia bota, a Matrix SDK zweryfikował pełny łańcuch właściciel → tożsamość bota → urządzenie bota. Zaktualizowana i ponownie uruchomiona aplikacja: Matrix ready / QR enabled oraz Hermes API ready, podpis bundle poprawny. Zniknięcie ostrzeżenia na fizycznym telefonie wymaga jeszcze sprawdzenia przez użytkownika.

Plan: `/Users/fine/.hermes/plans/2026-10-07_074438-pebble-hermes-macos-bridge.md`.
Użytkownik zatwierdził konfigurację, następnie nazwę Indexa i katalog `/Users/fine/Projekty/indexa`.
Katalog wcześniej nie istniał. Brak nadrzędnych AGENTS.md. Bez commitów i publikacji.

## Logowanie QR — wdrożone 2026-10-07

Poprawka po zgłoszeniu niewidocznego przycisku: ponowny start z Findera nie dziedziczył LANG/LC_ALL. PostgreSQL na macOS kończył się `postmaster became multithreaded during startup`, a UI uzależniało widoczność QR od odpowiedzi martwej usługi. `Tests/test_matrix_gui_start.py` odtworzył błąd w tymczasowym klastrze przy usuniętych zmiennych locale, następnie przeszedł po ustawieniu `LC_ALL=C` wyłącznie dla procesów Indexy. Przycisk QR jest teraz stale widoczny i pokazuje niedostępność serwera, zamiast znikać. Zaktualizowano tekst prowadzący do QR. Sprawdzenie zainstalowanej aplikacji po ponownym uruchomieniu: Matrix ready/QR enabled i Hermes API ready. Ustawień języka macOS, powłoki ani VPN nie zmieniano. Przyczyna macOS opisana też w [kodzie PostgreSQL](https://doxygen.postgresql.org/postmaster_8h.html).

Użytkownik zażądał logowania QR i jawnie zezwolił skonfigurować Matrix od nowa. Poprzednia instalacja została odłożona w `before-qr-*`; aktywne konto/pokój są nowe. Tailscale i służbowy VPN pozostały bez zmian.

Natywne MAS 1.26.0 (Rust, lokalny patch `--password-stdin` zapobiega hasłu w argv) + PostgreSQL 17.11, prywatny klaster przez socket Unix z peer authentication, rolą bez uprawnień administracyjnych, bez TCP i bez globalnej usługi brew. Synapse 1.162.0 nadal używa SQLite i własnego rendezvous MSC4108. Reverse proxy zajmuje dotychczasowy 127.0.0.1:18763, Synapse :18765, MAS :18766; prywatne Serve :8443 pozostaje identyczne. Trasy administracyjne nie przechodzą przez proxy.

SwiftUI → uwierzytelniony lokalny transport → krótkotrwały natywny proces Matrix Rust SDK 0.19.1. QR zawiera binarne dane MSC4108; nie hasło. Użytkownik wpisuje kod z telefonu, a następnie zatwierdza logowanie na stronie MAS wewnątrz WKWebView Indexy. Dane istniejącego konta są wypełniane tylko na `/login` przypiętego originu HTTPS; nawigacja poza ten origin zablokowana, magazyn przeglądarki nietrwały. Przekazanie cross-signingu sprawdza SDK; bot ufa wyłącznie dokładnie pasującym kluczom urządzeń zweryfikowanym przez tożsamość ownera. Para ma limit 180 sekund; zamknięcie okna ją anuluje. Proces QR nie działa poza parowaniem.

Sekrety nadal bez Keychain, w dotychczasowym lokalnym sejfie; prywatne klucze ownera w szyfrowanym magazynie SDK. MAS ma swoje klucze w prywatnym pliku 0600. Procesy tego samego konta macOS nie są od siebie izolowane. Python nie zapisuje bytecode do podpisanego bundle (zapobiega uszkodzeniu jego podpisu przy imporcie).

Walidacja: `Tests/test_matrix_qr_live.py` PASS dla blokady admin API, uwierzytelnienia sterowania QR, odrzucenia złego kodu, rzeczywistego loginu OAuth, transferu trzech kluczy cross-signingu, zaufania dokładnym kluczom telefonu i desktopu oraz wylogowania wyłącznie testowej sesji. `test_matrix_qr_boundaries.py` i dotychczasowy `test_matrix_journal.py` PASS; 16 testów Swift / 8 zestawów PASS. Build release i podpis po uruchomieniu PASS. Zainstalowana aplikacja potwierdziła Matrix ready + QR enabled oraz Hermes API ready. Test na fizycznym iPhonie pozostaje do wykonania; CUA uruchamia aplikację, lecz odczyt AX kończy się timeoutem, więc wygląd okna nie był sprawdzony automatycznie.

Dodatkowe MAS + PostgreSQL: suma RSS 134,7 MiB i próbka CPU 0,0% po starcie. RSS może liczyć współdzielone strony wielokrotnie; to pojedynczy pomiar, nie gwarancja stałego zużycia. Bez kontenera/VM. Kompilacja ograniczona do dwóch zadań. Odtworzenie builda: `scripts/build-matrix-qr.sh`, następnie `scripts/build-app.sh`; świeży setup wymaga zatrzymanej aplikacji i jawnego `--reset-authorized` dla skompilowanego `scripts/configure-matrix-qr.swift`.

## Aktualny stan uruchomienia: Matrix i Hermes API

2026-10-07: skonfigurowano Matrix bez Keychain przez `scripts/configure-matrix.swift` i `matrix/setup.py`. Hasła kont i klucz crypto zapisuje Swift w istniejącym magazynie przed bootstrapem; Python dostaje tylko dwa hasła przez stdin i zwraca token bota przez stdout, bez wypisywania wartości w diagnostyce. Potwierdzono, że poprzednia instalacja nie miała wiadomości, urządzeń właściciela ani zadań; zachowano ją wraz ze starą bazą bridge w `~/Library/Application Support/Indexa/before-local-vault-20261007-201016`. Nowe konta owner/indexa są nieadministracyjne; pokój prywatny i szyfrowany, bez federacji. Tymczasowy sekret rejestracji usunięty, rejestracja publiczna wyłączona. Keychain nie był odczytywany ani zmieniany.

Hermes odmawiał startu profilu kodem 78, ponieważ domyślnie wymaga host gatewaya. Przez CLI ustawiono w profilu `indexa` `gateway.standalone=true` oraz jawne `platforms.api_server.enabled=true`. `gateway.multiplex_profiles=false` pozostaje. Odczyt źródła i odpowiedź CLI potwierdzają, że standalone to tymczasowy mechanizm zgodności tej wersji; config linter błędnie zgłasza nierozpoznany klucz, ale gateway go respektuje. To standalone było potwierdzoną przyczyną odmowy startu, nie sama wcześniejsza nieobecność flagi API: środowiskowy API_SERVER_KEY również aktywuje adapter. Profil default nie był modyfikowany.

Test rzeczywistych usług po restarcie: 127.0.0.1:18761 (Indexa), :18762 (Hermes), :18763 (Synapse), :18764 (transport). API potwierdza run_submission, trwałe runs_idempotency (24h) i run_approval_response. Hermes i transport zwracają 401 bez uwierzytelnienia. `Tests/test_matrix_live.py` zaliczył zaszyfrowane owner → Indexa → owner dla `!status`; tymczasowe urządzenie ma porównany rzeczywisty klucz publiczny i jest wylogowywane w finally. Test nie uruchamiał LLM. Test iPhone/Element X, push, realne zadanie modelu i Apple Notes nadal oczekują.

Poprawiono dwa błędy ujawnione przez realny test: lista urządzeń używa `OlmDevice.verified` zamiast nieistniejącego `AsyncClient.is_device_verified`; pierwszy sync po restarcie czyści lokalny znacznik deduplikacji nio, zachowując trwały `since`, aby nie zgubić pełnego stanu pokoju przy niezmienionym tokenie serwera. Oba mają testy regresji w `Tests/test_matrix_journal.py`. Test `test_matrix_setup.py` blokuje zastąpienie instalacji zawierającej wiadomości, urządzenia właściciela lub pracę. Nie zmieniano Tailscale ani służbowego VPN i nie testowano połączenia z iPhone'a.

## Aktualna decyzja: bez Keychain i bez dodatkowego konta macOS

**Najnowsza zmiana:** użytkownik odrzucił ręczne wpisywanie hasła i wybrał losowy klucz zapisywany lokalnie. Nowa instalacja tworzy automatycznie `secrets.vault.key` (256 bitów losowości zapisanych jako 64 znaki hex, plik 0600 w katalogu 0700), następnie szyfruje sejf przy użyciu tego klucza jako passphrase. Przy starcie odczytuje go automatycznie; brak Keychain i promptu hasła. Klucz jest zapisywany przed sejfem; przerwany pierwszy start można wznowić. Nie nadpisujemy istniejącego klucza, odrzucamy symlinki/niewłaściwego właściciela/uprawnienia/format. Istniejący sejf bez klucza pozostaje nietknięty i wymaga swojego wcześniejszego hasła. Na tym Macu przed wdrożeniem nie było jeszcze sejfu.

Klucz obok zaszyfrowanego pliku oznacza ochronę opartą na uprawnieniach konta i ewentualnym szyfrowaniu dysku, nie odporność na odczyt przez inny proces tego samego użytkownika lub kradzież obu plików. Nie sprawdzano ani nie zmieniano FileVault. Nie jest to pełna izolacja. Backup/odtworzenie wymaga obu plików. To świadomie wybrany wariant wygody, zastępujący opisane niżej ręczne odblokowanie.

Walidacja aktualizacji: 16 testów Swift / 8 zestawów PASS; obejmuje automatyczne otwarcie po restarcie magazynu, trwałość klucza, tryb 0600, odmowę zastąpienia istniejącego sejfu, wznowienie po zapisie samego klucza i odrzucenie uszkodzonego klucza.

Użytkownik odrzucił płatne Apple Developer i dodatkowe konto systemowe; wybrał rezygnację z Keychain. Ten wybór zastępuje opisany niżej wariant DP/provisioning. Integracja Keychain została usunięta, a istniejących wpisów nie odczytujemy, nie migrujemy i nie usuwamy.

SecretStore zapisuje wyłącznie `secrets.vault`: AES-256-GCM (CryptoKit), świeży losowy nonce przy zapisie, klucz wyprowadzany z hasła przez PBKDF2-HMAC-SHA256 / 600 000 iteracji (CommonCrypto), losowa sól 16 bajtów. Wersja formatu i sól są uwierzytelniane. Katalog 0700, plik 0600, zapis atomowy zaszyfrowanej zawartości, blokada wyłączna między instancjami. Nie ma automatycznego odblokowania, hasła w konfiguracji/środowisku ani fallbacku do innego magazynu. Co najmniej 16 znaków dla nowego hasła. Brak odzyskiwania zapomnianego hasła.

Po uruchomieniu użytkownik tworzy/odblokowuje sejf w oknie Indexy. Dopiero wtedy możliwy jest start usług. Brak tokenu bota lub klucza jego magazynu blokuje start przed uruchomieniem Hermesa/Matrix. Dane istniejącej sesji można wprowadzić ręcznie w Ustawieniach; przygotowanie nowej sesji bez starych danych jest oddzielnym, jeszcze niewykonanym krokiem. Nowy sekret Pebble będzie wymagał aktualizacji konfiguracji pierścienia.

Zakres ochrony: zaszyfrowane sekrety na dysku. To nie jest izolacja systemowa od innych procesów tego samego użytkownika; działające usługi otrzymują potrzebne sekrety, a Swift/CryptoKit nie gwarantują wyzerowania każdej kopii w pamięci. Szyfrowanie sejfu nie obejmuje baz danych wiadomości, profilu dostawcy LLM ani całego katalogu Synapse. Konto macOS, sieć i służbowy VPN pozostają bez zmian.

Walidacja: 15 testów Swift przechodzi, w tym nowy test obejmujący odczyt po restarcie magazynu, błędne hasło, manipulację ciphertextem, odmowę nadpisania istniejącego sejfu, uprawnienia pliku, blokadę drugiej instancji i brak jawnych sekretów w pliku. Poprzednie testy entitlements zastąpił test nowego magazynu. Nie wykonano realnego testu Matrix/Notes ani nie odblokowano sejfu użytkownika.

Źródła implementacji: [Apple AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm), [OWASP PBKDF2](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html), [OWASP Cryptographic Storage](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html).

## Historyczny wariant: pełna izolacja z Keychain (wycofany)

Użytkownik ponownie zatwierdził Keychain pod warunkiem pełnej izolacji: Indexa ma mieć dostęp wyłącznie do własnych sekretów, a procesy AI nie mogą sięgać do pozostałych haseł użytkownika. Usługi pozostają wstrzymane. Niczego z Pęku kluczy nie usunięto ani nie migrowano.

Kod wybiera Data Protection Keychain, zamkniętą listę nazw i pojedynczą grupę podpisanej aplikacji, bez fallbacku do legacy. Centralna blokada w KeychainStore odrzuca wszystkie operacje przed kontaktem z Keychain, również z ponownego połączenia i onboardingu. Matrix dostaje trzy potrzebne sekrety przez stdin; Python nie czyta już Keychain. To przygotowanie, a nie ukończona izolacja systemowa.

Brakuje zatwierdzonego podpisu/profilu Apple i zweryfikowanej granicy procesów. Sam podpis ani grupa DP nie wystarczą do pełnego wymagania. Skrypt buduje obecnie wyłącznie zablokowany podgląd. Szczegóły i warunki testów: [KEYCHAIN-ISOLATION-RESEARCH.md](KEYCHAIN-ISOLATION-RESEARCH.md). Poniższe sekcje discovery zawierają historyczne stany; nie są potwierdzeniem gotowości wdrożenia. Zgodnie z ostatnią dyspozycją nie zmieniamy Tailscale ani służbowego VPN.

Użytkownik nie ma płatnego Apple Developer. Nie wymagamy zakupu. Wariant DP/provisioning nie jest obecnie drogą wdrożenia. Kierunek do zweryfikowania: usługi na dedykowanym nieuprzywilejowanym koncie macOS, oddzielny file-based Keychain i mały broker bez kodu AI; GUI bez bezpośrednich operacji Keychain. TN3137 dopuszcza file-based Keychain w kontekście daemonów. Nie oznacza to gotowego rozwiązania: trzeba rozwiązać odblokowanie po restarcie, uwierzytelnienie IPC i ograniczony dostęp do Notes oraz przetestować odmowę dostępu do syntetycznych sekretów innego użytkownika. Nie utworzono konta ani nie zmieniono usług systemowych; dotychczasowa blokada pozostaje aktywna.

## Zmiana kanału: Matrix / Element X

Użytkownik zastępuje Telegram własnym Matrix, z dostępem przez prywatny Tailscale.
Poniższe wcześniejsze ustalenia o Telegramie są historyczne; nie należy konfigurować BotFather ani wdrażać obecnego odbiorcy Telegram.

**Aktualizacja po ograniczeniu zasobów:** użytkownik wykluczył kontener i VM. Pytanie o Colima/Docker jest nieaktualne. Potwierdzono natywną instalację matrix-nio 0.26.0 / vodozemac 0.10.0 i offline E2EE round-trip na tym Macu. Wybieramy ten SDK jako transport Indexa do istniejącego Runs API, bez zmiany biblioteki w głównym Hermesie. Szczegóły, pomiar i ograniczenia w [MATRIX-MACOS.md](MATRIX-MACOS.md). Wcześniejsze stwierdzenie, że szyfrowanie wymaga Linuxa, dotyczyło wyłącznie wspieranej instalacji obecnego adaptera mautrix Hermesa i było zbyt szerokie.

- Element X jest klientem. Nadal potrzebny jest homeserver; proponowany Synapse na tym Macu, bez federacji i otwartej rejestracji. Dostęp z iPhone’a wymaga aktywnego Tailscale.
- Kod konfiguratora i UI sieci zmieniono na prywatny Serve. Usuwa wyłącznie własne AllowFunnel, zachowuje inne usługi i odmawia nadpisania zajętego portu. Zmiany rzeczywistej konfiguracji Tailscale jeszcze nie wykonano.
- Hermes ma natywny adapter mautrix. W tym checkoutcie extra `matrix` jest ograniczone do Linuxa: vendored python-olm nie buduje się na aktualnym macOS. Dokumentacja zaleca lokalny kontener Linux w trybie proxy; sam agent i Notes mogą pozostać na Macu. Nie instalowano Colima/Docker; wysłano pytanie o zgodę na dodatkowe kilka GB zgodnie z ograniczeniem dużych pakietów w planie.
- Nie wolno uznać zwykłego proxy `/v1/chat/completions` za gotowy zamiennik Indexa Runs API. W kodzie proxy przekazuje własny `X-Hermes-Session-Id`, nie ma mapowania do trwałej kolejki Indexa ani jej approvals. Native Matrix ignoruje zdarzenia starsze niż 5 sekund przed startem. Integracja musi zachować jedną sesję ring/Matrix, durable inbox/outbox i bezpieczne zgody; nie została jeszcze wdrożona.
- Standardowe powiadomienia Element na iOS używają push gateway i Apple APNs. Własny homeserver nie oznacza całkowitego usunięcia zewnętrznej infrastruktury powiadomień. Realny test zablokowanego iPhone’a pozostaje konieczny.
- Tailscale szyfruje transport; połączenie może korzystać z szyfrowanego relay DERP, gdy bezpośrednie nie jest możliwe. Nie obiecujemy zawsze bezpośredniej trasy ani działania bez Internetu.
- Ustawienia dostawcy LLM i transkrypcji Pebble pozostają osobnymi kwestiami. Lokalny Matrix nie czyni przetwarzania modelu automatycznie lokalnym.

Stan sprawdzenia: `bash scripts/test-local.sh` — 15 testów, 8 zestawów, PASS. Obejmuje nowy test prywatnego Serve; nie jest testem działającego Matrix. Kod transportu Telegram jeszcze wymaga zastąpienia. Aplikacja nie została wdrożona ani uruchomiona jako usługa użytkownika.

Źródła aktualizacji:
- [Hermes Matrix i macOS proxy](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/matrix#proxy-mode-e2ee-on-macos)
- [Synapse instalacja](https://element-hq.github.io/synapse/latest/setup/installation.html)
- [Element push notifications](https://docs.element.io/latest/element-support/element-androidios-client-settings/understanding-push-notifications/)
- [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)

## Zweryfikowane środowisko

- macOS 26.5.1 arm64, Swift 6.3.3, Command Line Tools. Pełnego Xcode nie ma. Typecheck SwiftUI, ServiceManagement, Security, CryptoKit i SQLite3 zakończył się kodem 0.
- Hermes `vgit.8273265 (2026.9.24)`, checkout `82732650a18f303c2ac3e305f3c12a122ef1649a`, Python 3.14.7.
- Początkowo tylko profil default, bez skonfigurowanego Telegrama i API_SERVER_KEY. GET localhost:8642/health i /v1/capabilities: connection refused. Nie czytano wiadomości ani state.db.
- Tailscale Standalone `io.tailscale.ipn.macsys` 1.102.3; po uruchomieniu przez użytkownika Running/online. Brak Serve/Funnel config.
- Skill hermes-agent i apple-notes znalezione lokalnie. memo nie jest w PATH; interaktywny memo nie nadaje się do automatycznego create/append. Brak skilla subagent-driven-development. Implementacja bez delegowania.

## Wybory

- Natywne SwiftUI MenuBarExtra, systemowe SQLite3/Keychain/CryptoKit/URLSession, jeden proces Indexa.
- Vapor 4.122.2 (manifest Swift 6.0), przypięty dokładnie; gotowy parser MultipartKit. Vapor main wymaga Swift 6.4 i nie pasuje do lokalnego toolchaina. Transitive pins zostaną zapisane w Package.resolved po rozwiązaniu zależności.
- Osobny profil Hermes `indexa`, konfiguracja przez CLI; obecny default pozostaje bez zmian. Dedykowany bot; bridge wyłącznym konsumentem getUpdates.
- Runs API: POST /v1/runs z input, session_id, instructions i trwałym Idempotency-Key; GET /v1/runs/{run_id}; POST /stop i /approval. Publiczny GET /health, uwierzytelniony /v1/capabilities. W lokalnym kodzie flaga approvals to `run_approval_response`, a nie sugerowane w docs `run_approval`.
- Approval body: choice=once/deny oraz dokładne request_id. Nigdy session/always/all. Stan polling zawiera approval. Jawna sesja; bez resume latest.
- Idempotencja w kodzie ma retencję 24h i może przejść na pamięć przy błędzie dysku. Bridge sprawdza `durable`; nie ponawia niejednoznacznego submit po oknie retencji. Wymagany test rzeczywistego API po uruchomieniu.
- Testowane granice zgodnie z zaakceptowanym planem: konfiguracja/Keychain, publiczny ingest, trwały inbox/outbox/recovery, klienci HTTP, właściciel Telegram/approvals, wspólna sesja, natywne UI/bundle. TDD pionowymi fragmentami.

## Tailscale API

Publiczne REST API zarządza tailnetem. Dla lokalnego klienta właściwe jest LocalAPI.
Na tym Macu port pochodzi z `/Library/Tailscale/ipnport`, krótkotrwały token z `sameuserproof-<port>`; Basic auth wyłącznie w pamięci, Host `local-tailscaled.sock`, połączenie 127.0.0.1.
Odczyty `GET /localapi/v0/status?peers=false` i `GET /localapi/v0/serve-config` sprawdzone: HTTP 200.
`POST /localapi/v0/serve-config` używa `If-Match` z ETag; aktualizuje konfigurację z zachowaniem innych usług. Interfejs niestabilny: brak zgodności ma dawać błąd, nie zielony status. CLI aplikacji Tailscale pozostaje drogą oficjalnego onboardingu Funnel/HTTPS i polityki tailnet.

Źródła:
- [Hermes API](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server)
- [Pebble kontrakt](https://github.com/coredevices/mobileapp/blob/c24d10720931c4df28a72378d8c71b9f4de84c35/experimental/src/commonMain/kotlin/coredevices/ring/external/indexwebhook/INDEX_WEBHOOK_API.md)
- [Tailscale LocalAPI](https://github.com/tailscale/tailscale/blob/v1.102.3/client/local/serve.go)
- [Tailscale macOS transport](https://github.com/tailscale/tailscale/blob/v1.102.3/safesocket/safesocket_darwin.go)
- [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel)
- [Vapor manifest](https://github.com/vapor/vapor/blob/4.122.2/Package.swift)

## Otwarte testy sprzętowe

BotFather/token, parowanie, iOS powiadomienie, realne nagranie, Notes Automation i read-back, sleep/wake/login. Nie są zaliczone przez sam build ani syntetyczne testy.
