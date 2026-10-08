# Matrix na macOS bez kontenera — 2026-10-07

## Wniosek

Linux ani maszyna wirtualna nie są wymaganiem protokołu Matrix. Synapse dokumentuje natywną instalację na macOS, a nowszy Python SDK ma gotowe biblioteki szyfrowania dla Apple Silicon. Ograniczenie dotyczy pakowania obecnego adaptera Hermes: checkout `82732650a18f303c2ac3e305f3c12a122ef1649a` przypina `mautrix[encryption]==0.21.1` tylko dla Linuxa, ponieważ jego `python-olm` ma problemy z budowaniem na aktualnym macOS. Zalecany w dokumentacji Hermes kontener omija tę przeszkodę, lecz nie jest jedyną możliwą architekturą. [Hermes Matrix](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/matrix#proxy-mode-e2ee-on-macos), [Synapse instalacja](https://element-hq.github.io/synapse/latest/setup/installation.html).

## Najmniejszy utrzymywany wariant bez Linuxa

Natywny Synapse + mały proces transportowy Indexa używający `matrix-nio[e2e]==0.26.0` + istniejące lokalne Runs API Hermes. To rekomendacja integracyjna, nie potwierdzenie zakończonego wdrożenia. Nie wymaga zmieniania domyślnego środowiska Hermes ani wyłączania E2EE.

Wydanie matrix-nio 0.26.0 z 23 lipca 2026 zastąpiło libolm przez vodozemac. Potwierdzono rzeczywiste `Requires-Dist` przez HTTPS do PyPI JSON oraz kod opublikowanego commita; tekst README na stronie PyPI nadal zawiera stare instrukcje libolm. [Metadane wydania](https://pypi.org/pypi/matrix-nio/0.26.0/json), [niezmienny pyproject wydania](https://github.com/matrix-nio/matrix-nio/blob/331c93ed3e9ca86e7444b4dfdf05086654842ace/pyproject.toml), [ogłoszenie Matrix](https://matrix.org/blog/2026/07/24/this-week-in-matrix-2026-07-24/).

| Pakiet | Dostępna paczka | Rozmiar pobrania |
| --- | --- | ---: |
| matrix-nio 0.26.0 | `py3-none-any` | 183 482 B |
| vodozemac 0.9.0.post2 | CPython 3.11, macOS 11+ arm64 | 677 544 B |
| vodozemac 0.9.0.post2 | CPython 3.12, macOS 11+ arm64 | 675 795 B |
| vodozemac 0.9.0.post2 | CPython 3.13, macOS 11+ arm64 | 675 796 B |
| vodozemac 0.9.0.post2 | CPython 3.14, macOS 11+ arm64 | 676 078 B |

Źródła tabeli: [matrix-nio PyPI JSON](https://pypi.org/pypi/matrix-nio/0.26.0/json), [vodozemac PyPI JSON](https://pypi.org/pypi/vodozemac/0.9.0.post2/json). To rozmiary dwóch paczek, nie całego środowiska ani zużycie RAM. vodozemac nie deklaruje dodatkowych zależności Python. matrix-nio wymaga Python >=3.10; oprócz bibliotek HTTP/walidacji jego extra E2EE dodaje `atomicwrites~=1.4`, `cachetools>=5.3`, `peewee~=3.14`, `vodozemac>=0.9.0.post2`.

matrix-nio nie jest zamiennikiem API mautrix: potrzebny jest transport do trwałego inbox/outbox Indexa. Biblioteka deklaruje obsługę E2EE, szyfrowanych załączników i weryfikacji urządzeń, ale brak cross-signing i serwerowej kopii kluczy. Trzeba sprawdzić weryfikację z Element X, zachowanie kluczy po restarcie oraz backup lokalnego magazynu. [Funkcje nio](https://pypi.org/project/matrix-nio/0.26.0/).

Synapse opisuje zwykły Python venv, Python 3.10–3.13, macOS i Command Line Tools; na ARM czasem potrzeba jpeg/libpq. Zatem wspólnym rozsądnym interpreterem dla serwera i transportu jest 3.13, w osobnym środowisku od Hermes 3.14. To wybór na podstawie dokumentowanej zgodności; uruchomienie i pomiary zasobów nadal wymagają testu. [Instalacja Synapse](https://element-hq.github.io/synapse/latest/setup/installation.html).

## Dlaczego samo brew libolm nie rozwiązuje adaptera Hermes

`python-olm==3.2.16` kompiluje dołączoną kopię libolm. Zgłoszenia w głównym repozytorium potwierdzają dwa niezależne błędy: Apple Clang 17 odrzuca inkrementację `T * const other_pos`, a CMake 4 odrzuca zgodność z wersją poniżej 3.5. [Olm #99](https://github.com/matrix-org/olm/issues/99), [Olm #100](https://github.com/matrix-org/olm/issues/100).

Dla drugiego błędu oficjalny mechanizm to `CMAKE_POLICY_VERSION_MINIMUM=3.5` w środowisku procesu budowania albo argument `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`. To zmienia polityki konfiguracji, nie naprawia błędu C++. [Dokumentacja CMake](https://cmake.org/cmake/help/latest/envvar/CMAKE_POLICY_VERSION_MINIMUM.html).

Nie znaleziono wydanego upstreamowego rozwiązania błędu wskaźnika. Lokalna zmiana na wskaźnik do const wymaga też sprawdzenia reszty kopiowania oraz testów; nie należy przedstawiać jej jako oficjalnie wspieranej instalacji. Użycie GCC opisane w innym projekcie jest obejściem zgłoszonym przez społeczność, nie naprawą biblioteki. Dodatkowy kompilator byłby zbędnym ciężarem, skoro dostępny jest gotowy backend vodozemac.

libolm został zdeprecjonowany w 2024 r.; jego repozytorium GitHub jest zarchiwizowane. Matrix kieruje utrzymanie do vodozemac. Oficjalne omówienie wymienia CVE-2024-45191/45192/45193 oraz zastrzega, że w chwili publikacji nie znano praktycznej eksploatacji sieciowej. Nie należy przedstawiać starej biblioteki jako automatycznie przełamanej, ale kompilacja z lokalną poprawką nie przywraca jej utrzymania. Kontener używający tej samej biblioteki także tego nie zmienia. [Omówienie deprecjacji](https://matrix.org/blog/2024/08/libolm-deprecation/), [stan repozytorium](https://github.com/matrix-org/olm).

## Stan tej analizy

Użytkownik wykluczył kontener/VM: Indexa ma działać w tle na Macu używanym do pracy.

Oprócz źródeł wykonano izolowaną instalację w `/private/tmp/indexa-native-matrix/venv` na już dostępnym Pythonie 3.11.15. Niezmienione python-olm 3.2.16 nie zbudowało się (potwierdzony błąd Clang). Następnie `matrix-nio[e2e]==0.26.0` i `vodozemac==0.10.0` zainstalowały się natywnie bez zmian kodu. Nie zmieniano środowiska Hermesa.

`Tests/test_matrix_crypto.py` przeszedł: szyfrowanie/odszyfrowanie tekstu Unicode, zapis i odtworzenie klucza sesji, odrzucenie złego hasła. Peak RSS izolowanego testu wyniósł 52,2 MiB (`resource.getrusage`); NIE jest to pomiar pełnej aplikacji, procesu bezczynnego, homeservera ani Hermesa. Próba pomiaru przez `time -l` miała błąd uprawnienia `sysctl` po udanym teście; powtórzenie przez Python zakończyło się kodem 0.

Nie uruchomiono homeservera ani nie wysłano wiadomości. Pełna integracja, weryfikacja urządzenia Element X, trwałość synchronizacji oraz pomiary CPU/RAM w tle pozostają do wykonania. Wybrana droga to natywny transport Indexa z nio i lokalne Runs API Hermesa; Linux nie jest już planowany.
