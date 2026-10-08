# Wydania i odzyskiwanie Indexy

## Co aktualizuje archiwum

Sparkle wymienia aplikację, jej biblioteki, transport Matrix i natywny pomocnik QR. Przed uruchomieniem usług Indexa sprawdza `Resources/stack.json`, a następnie wdraża do profilu `indexa` dołączony plugin Notes. Aktualizacja nie zastępuje sejfu, kont, kluczy szyfrowania, baz ani ustawień użytkownika.

Obsługiwane istniejące środowisko opisuje [release/stack.json](../release/stack.json): Python 3.11, Synapse 1.162.0, matrix-nio 0.26.0, vodozemac 0.10.0, PostgreSQL 17 oraz natywny MAS 1.26.0 z poprawką przyjmowania hasła przez stdin. Ten build MAS zwraca `VERGEN_IDEMPOTENT_OUTPUT` zamiast wersji, dlatego kontrolowany jest SHA-256 konkretnego wdrożonego pliku. Hash nie jest obietnicą identycznych wyników niezależnej kompilacji MAS.

Python, MAS i PostgreSQL pozostają poza aplikacją. Hermes również pozostaje zewnętrznym komponentem; musi mieć skonfigurowany profil `indexa` i wymagane API. Nieobsługiwany runtime zatrzymuje start przed uruchomieniem gatewaya. **Automatyczna migracja zewnętrznych zależności i schematów Matrix/PostgreSQL nie jest wdrożona.** Będzie wymagała osobnego planu, kopii danych i testu odtworzenia przy pierwszej zmianie tych wersji. Nie należy obchodzić tej blokady przez samo zmienienie manifestu.

## Publikacja

1. Zaktualizuj `release/version.txt` i opcjonalnie dodaj `release-notes/X.Y.Z.md`.
2. Uruchom testy i zbuduj aplikację. Sprawdź istniejącą instalację bez resetowania Matrixa.
3. Utwórz i wypchnij tag `vX.Y.Z`. `.github/workflows/release.yml` buduje natywne QR, testuje Swift/Python, pakuje aplikację, podpisuje ZIP i publikuje ZIP oraz `appcast.xml` w tym samym repozytorium.

Workflow używa `SPARKLE_PRIVATE_KEY` z GitHub Actions Secrets. Własny klucz Indexy utworzono bez Keychain; lokalna kopia znajduje się w ignorowanym `.sparkle/private-key` z uprawnieniami `0600`. W repozytorium jest tylko `release/sparkle-public-key.txt`. Nie uruchamiaj generatora ponownie dla kolejnej wersji. Utrata lub zmiana klucza wymaga osobnej procedury rotacji Sparkle.

Kanał to `https://github.com/this-is-fine-dev/indexa/releases/latest/download/appcast.xml`. Repozytorium musi być publiczne, aby aplikacja pobierała go anonimowo. Podpis Ed25519 chroni integralność aktualizacji; podpis aplikacji pozostaje ad-hoc i nie zastępuje notarizacji Apple. Archiwum ZIP nie jest bitowo odtwarzalne między niezależnymi kompilacjami: podpisujemy i weryfikujemy dokładnie ten plik, który publikuje CI.

Po wygenerowaniu kanału `Tests/test_release_package.py dist/update/appcast.xml` weryfikuje podpis rzeczywistego ZIP-a, długość, zgodność klucza osadzonego w aplikacji i obecność wymaganych komponentów. Nie regeneruj ZIP-a po podpisaniu.

## Restart i przerwana aktualizacja pluginu

Aplikacja kończy pętle i czeka na zamknięcie dzieci przed zgodą na zakończenie. Jeżeli usługi nadal pracują, odmawia zakończenia i zachowuje blokadę instancji; poczekaj i ponów. Nie uruchamiaj drugiej kopii i nie usuwaj ręcznie plików blokad. Dłuższe opróżnianie połączeń proxy i baz może przekroczyć pierwszy czas oczekiwania aplikacji.

Plugin jest przygotowywany w `~/.hermes/profiles/indexa/indexa-plugin-backups/staged`. Stary katalog jest przenoszony do `pending`, potem nowy katalog zajmuje jego miejsce. Pliki i katalogi są synchronizowane na dysk. Stała nazwa `pending` jest zapisem niedokończonej operacji:

- Jeżeli po awarii brakuje pluginu docelowego, następny start najpierw przywraca `pending`.
- Jeżeli plugin docelowy istnieje, instalacja się zakończyła i `pending` staje się zachowaną kopią pod nazwą UUID.
- Pozostałe pliki `staged` są odrzucane; usług nie uruchamia się z częściowym pluginem.

Kopie pozostają poza katalogiem `plugins`, aby Hermes nie ładował dwóch wersji. Test `Tests/test_runtime_update.py` sprawdza również rzeczywiste zakończenie procesu między przeniesieniami, z pominięciem obsługi wyjątków.

## Wycofanie wydania

Zakończ Indexę i potwierdź zatrzymanie usług. Zachowaj bieżące dane. Zainstaluj poprzednią zaufaną aplikację zgodną z tym samym manifestem runtime; przy następnym starcie wdroży ona swój plugin. Automatyczne obniżanie wersji baz danych nie jest obsługiwane — przed takim wydaniem konieczny jest oddzielnie przetestowany backup/restore.

Dla wersji sprzed wprowadzenia pakowanego pluginu trzeba po zamknięciu gatewaya ręcznie przywrócić właściwą kopię `indexa-plugin-backups/<UUID>` do `plugins/indexa-notes`. Nie kopiuj starych baz nad działającymi procesami i nie uruchamiaj ponownie skryptów tworzenia kont w celu naprawy aktualizacji.

## Testy przed uznaniem wydania za sprawdzone

CI sprawdza logikę kolejki, trwałość, granice zaufania QR, szyfrowanie, plugin i podpis archiwum. Osobno wymagają próby na Macu: aktualizacja poprzedniej zainstalowanej wersji, zamknięcie podczas zadania, sen/wybudzenie, logowanie do macOS oraz powiadomienie na zablokowanym iPhonie. Zielone CI nie oznacza wykonania tych prób.
