# Izolacja Keychain na macOS — 2026-10-07

## Wniosek

Obecny podpis ad-hoc Indexa nie wystarcza do wdrożenia izolacji Data Protection Keychain opartej na zatwierdzonej tożsamości aplikacji. Apple wymaga, aby uprawnienia grup Keychain były autoryzowane profilem provisioning; lokalny podpis `codesign --sign -` ani własny certyfikat nie zastępują profilu Apple. App Sandbox można włączyć bez tego profilu, ale nie jest to dowód ograniczenia wszystkich wywołań Keychain do elementów utworzonych przez Indexa. [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains), [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

**Dwa odrębne wymagania:** chronić sekrety Indexa przed innymi procesami oraz odebrać Indexa/Hermes/Python możliwość dostępu do cudzych sekretów. ACL własnego wpisu rozwiązuje pierwszą stronę; nie ustanawia drugiej.

## Co Apple rzeczywiście gwarantuje

- macOS ma dwa mechanizmy: file-based Keychain z ACL (`SecAccess`) oraz Data Protection Keychain z grupami dostępu. `SecItem` domyślnie używa pierwszego; `kSecUseDataProtectionKeychain: true` wybiera drugi. `SecKeychain*` zawsze używa pierwszego. Źródło: [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
- Grupy DP pochodzą z podpisanych entitlements głównego executable, autoryzowanych profilem provisioning. Biblioteka w procesie dziedziczy tę tożsamość; nie otrzymuje osobnej bariery. Samodzielne narzędzie CLI wymaga opakowania w bundle pozwalające umieścić profil. Źródło: [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
- `keychain-access-groups` jest entitlement ograniczonym; wpisanie go do ad-hoc entitlements nie upoważnia procesu. Entitlements App Sandbox i Hardened Runtime należą do kategorii niewymagającej profilu. Źródło: [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).
- Autoryzacja DP dotyczy grupy, nie historycznego twórcy każdego rekordu. Bez dodatkowych grup aplikacja ma własną grupę; aplikacje dopuszczone do tej samej grupy współdzielą jej wpisy. Mechanizm opisano dla DP, nie jako zakaz korzystania z legacy Keychain. Źródło: [Apple: sharing Keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).
- Dla file-based Keychain domyślny `SecAccess` ufa procesowi tworzącemu wpis. Można jawnie wskazać zaufane programy; późniejsza zmiana ACL wymaga autoryzacji użytkownika. To kontrola dostępu do konkretnego wpisu, a nie lista wszystkich wpisów, których aplikacja może szukać. Źródło: [Apple DTS](https://developer.apple.com/forums/thread/836816).
- App Sandbox to mechanizm egzekwowany przez kernel ograniczający m.in. pliki, sieć i zasoby. Dokumentacja nie daje prostego uprawnienia typu „Keychain: tylko wpisy utworzone przez ten proces”. Nie należy wyprowadzać takiej gwarancji z samego włączenia sandboxa. Źródło: [App Sandbox configuration](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).

## Stan Indexa przy odczycie kodu

`Sources/IndexaCore/SecretStore.swift` filtruje po `service` i `account`, ale nie wybiera DP. Filtr zapytania nie jest zabezpieczeniem egzekwowanym przez system. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` nie przełącza samodzielnie na DP i nie oznacza zakazu odczytu innych rekordów.

`scripts/build-app.sh` podpisuje ad-hoc bez App Sandbox. `Runtime.swift` uruchamia zewnętrzne Hermes i Python przez `Process`, z prawami tego samego użytkownika. Aktualnego stanu nie można opisać jako pełnej izolacji systemowej. To ustalenie statyczne; nie odczytywano rzeczywistych haseł ani listy cudzych wpisów.

## Wykonalna architektura i blokady

1. Mały natywny broker sekretów przechowuje wyłącznie jawnie zdefiniowane sekrety Indexa. Preferowany DP z własną grupą, bez dodatkowego Keychain Sharing. Broker nie przyjmuje dowolnego słownika zapytania, ścieżki Keychain ani nazwy usługi z procesu agenta. Potrzebna prawidłowa tożsamość podpisu i provisioning — obecnie ich brak. To blokada tej ścieżki, nie powód do osłabienia kontroli.
2. Hermes/Python/Matrix są oddzielnymi procesami, nie bibliotekami w brokerze. Otrzymują jedynie konkretne potrzebne wartości przez kontrolowane IPC. Bez udowodnionego systemowego odcięcia od Keychain pozostają procesami tego samego użytkownika; allowlista narzędzi Hermes ani czyste środowisko nie zastępują izolacji systemowej.
3. Podpisanie brokera i DP poprawiają ochronę własnych sekretów, ale nie dowodzą, że przejęty proces macOS nie spróbuje legacy Keychain. Jeżeli wymaganie obejmuje również całkowite odcięcie procesów od istniejącego Keychain użytkownika, potrzebna osobna granica wykonania i testy odrzucenia. Nie ma podstaw do obiecania tego samym App Sandbox.
4. Bez VM możliwym kierunkiem jest osobny nieuprzywilejowany użytkownik systemowy dla procesów agenta, z własnym katalogiem danych i bez odziedziczonej sesji użytkownika. To wniosek architektoniczny z per-user kontekstu Keychain; wymaga weryfikacji dostępu do plików, IPC i uruchamiania usług, uprawnień administratora oraz osobnego brokera dla Notes. Nie jest gotową ani sprawdzoną konfiguracją. Apple opisuje, że DP wybiera Keychain według kontekstu użytkownika i nie działa w zwykłym kontekście demona systemowego. [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

`sandbox-exec` nadal istnieje w tym systemie, lecz jego lokalna strona podręcznika oznacza go jako deprecated i odsyła aplikacje do App Sandbox. Profil blokujący komunikację z usługami bezpieczeństwa mógłby być dodatkowym mechanizmem dla pomocników, ale bez udokumentowanego stabilnego kontraktu i testów nie należy przedstawiać go jako pełnej, wspieranej przez Apple izolacji. Ten research nie wdrożył ani nie zweryfikował takiego profilu.

## Minimalna weryfikacja przed deklaracją bezpieczeństwa

Testować wyłącznie nowe syntetyczne rekordy: własny rekord oraz rekord kontrolny utworzony przez osobny proces. Potwierdzić: broker czyta własny, nieuprawniony proces nie czyta własnego brokera, każdy proces pomocniczy nie czyta kontrolnego rekordu przez DP ani legacy API, brak promptów rozszerzających dostęp, odmowa pozostaje po restarcie i przebudowaniu. Kontrole plików i IPC muszą również wykluczyć obejście izolacji przez wywołanie nieizolowanego procesu. Test pozytywny własnego wpisu nie wystarcza.

Przeczytano aktualny JSON TN3137/TN3125 z serwera Apple, dokumentację, odpowiedź Apple DTS oraz wymienione pliki projektu. Nie instalowano certyfikatów, nie zmieniano Keychain, uprawnień ani konfiguracji systemu.
