import SwiftUI
import AppKit
import IndexaCore

struct MenuView:View {
    @ObservedObject var runtime:Runtime
    @Environment(\.openWindow) var openWindow
    @State private var confirmReconnect=false
    var body:some View {
        Text("Indexa").font(.headline)
        Text(runtime.summary)
        Button("Otwórz Indexa") { openWindow(id:"indexa");NSApp.activate(ignoringOtherApps:true) }.keyboardShortcut("o")
        SettingsLink { Text("Ustawienia…") }
        Divider()
        Button(runtime.paused ? "Wznów zadania":"Wstrzymaj nowe zadania") { Task { await runtime.togglePause() } }
        Button("Połącz ponownie…") { confirmReconnect=true }.disabled(runtime.restarting)
        Divider()
        Button("Sprawdź aktualizacje…") { Updater.shared.checkForUpdates() }
        Button("Zakończ Indexa") { NSApp.terminate(nil) }.keyboardShortcut("q")
            .confirmationDialog("Uruchomić ponownie lokalne usługi?",isPresented:$confirmReconnect) {
                Button("Uruchom ponownie") { Task { await runtime.reconnect() } }
            } message: { Text("Trwające zadanie może zostać przerwane i wymagać sprawdzenia skutków. Rozmowy i konto pozostaną zachowane.") }
    }
}

struct Dashboard:View {
    @ObservedObject var runtime:Runtime
    @State private var selected:TaskRecord?
    @State private var review:TaskRecord?
    @State private var delivery:OutboxItem?
    @State private var diagnostics=false
    @State private var noteReview=[String]()
    @State private var confirmNotes=false
    @State private var vaultPassphrase=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Image(systemName:"waveform.circle.fill").font(.largeTitle).foregroundStyle(.teal)
                VStack(alignment:.leading) { Text("Indexa").font(.largeTitle.bold());Text("Od pomysłu do zapisanej notatki").foregroundStyle(.secondary) }
                Spacer();SettingsLink { Label("Ustawienia",systemImage:"gear") }
            }
            Label(runtime.summary,systemImage:runtime.statusSymbol).font(.title2)
            HStack(spacing:20) {
                Label(runtime.hermesConnected ? "Hermes połączony":"Hermes niedostępny",systemImage:runtime.hermesConnected ? "checkmark.circle":"exclamationmark.circle")
                Label(runtime.matrixConnected ? "Rozmowa połączona":"Oczekiwanie na Matrix",systemImage:runtime.matrixConnected ? "lock.shield":"clock")
            }.font(.callout).foregroundStyle(.secondary)
            if !runtime.tailscaleConnected { Text("Tailscale jest niedostępny. Połączenie telefonu może nie działać; szczegóły w diagnostyce.").font(.caption).foregroundStyle(.orange) }
            if !runtime.notice.isEmpty { Text(runtime.notice).font(.callout).textSelection(.enabled) }
            if runtime.vaultNeedsPassphrase {
                GroupBox("Istniejący sejf") {
                    VStack(alignment:.leading,spacing:8) {
                        Text("Ten sejf utworzono wcześniej z własnym hasłem. Jego dane pozostają zachowane; nowe instalacje konfigurują klucz automatycznie.")
                        SecureField("Hasło sejfu",text:$vaultPassphrase)
                        Button("Odblokuj istniejący sejf") {
                            let passphrase=vaultPassphrase
                            vaultPassphrase=""
                            Task { await runtime.unlockVault(passphrase:passphrase) }
                        }.disabled(vaultPassphrase.isEmpty)
                    }.padding(6)
                }
            }
            HStack {
                Button(runtime.paused ? "Wznów":"Wstrzymaj") { Task { await runtime.togglePause() } }.disabled(!runtime.ready)
                Button("Zatrzymaj zadanie") { Task { await runtime.cancelActive() } }.disabled(!runtime.hasActiveTask)
                Spacer();Button("Diagnostyka") { diagnostics=true }
            }
            List {
                if !runtime.pendingNoteWrites.isEmpty {
                    Section("Notatki wymagające sprawdzenia") {
                        Text("Zapis mógł się zakończyć, ale nie otrzymaliśmy potwierdzenia. Sprawdź folder Indexa w Notatkach przed odblokowaniem kolejnych zapisów.")
                        ForEach(runtime.pendingNoteWrites,id:\.self) { id in Text(id).font(.caption.monospaced()).textSelection(.enabled) }
                        Button("Sprawdziłem skutki tych operacji…") { noteReview=runtime.pendingNoteWrites;confirmNotes=true }
                    }
                }
                if !runtime.approvals.isEmpty {
                    Section("Zgody") {
                        ForEach(runtime.approvals) { approval in
                            VStack(alignment:.leading) {
                                Text(approval.description)
                                HStack { Text(Runtime.stateLabel(approval.state)).foregroundStyle(.secondary);Spacer()
                                    Button("Zezwól raz") { Task { await runtime.decide(approval,choice:"once") } }.disabled(approval.state != "pending")
                                    Button("Odmów") { Task { await runtime.decide(approval,choice:"deny") } }.disabled(approval.state != "pending")
                                }
                            }
                        }
                    }
                }
                Section("Zadania") {
                    if runtime.tasks.count >= 200 { Text("Pokazujemy do 200 zadań, najpierw aktywne. Starsza rozmowa jest w Hermesie.").font(.caption).foregroundStyle(.secondary) }
                    if runtime.tasks.isEmpty { Text("Tu pojawią się polecenia z Pebble i Matrix.").foregroundStyle(.secondary) }
                    ForEach(runtime.tasks.prefix(200)) { task in
                        HStack {
                            VStack(alignment:.leading) { Text("\(task.source == "pebble" ? "Pierścień":"Matrix") · \(task.id.prefix(8))");Text(Date(timeIntervalSince1970:task.created),style:.time).font(.caption).foregroundStyle(.secondary) }
                            Spacer();Text(Runtime.stateLabel(task.state)).font(.callout)
                            Button("Szczegóły") { selected=task }
                            if task.state == "needs_review" { Button("Sprawdziłem…") { review=task } }
                        }
                    }
                }
                Section("Dostarczenie do Matrix") {
                    if runtime.outbox.filter({$0.state != "delivered"}).count > 30 { Text("Pokazujemy pierwsze 30 oczekujących wiadomości z bieżącego podglądu kolejki.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(runtime.outbox.filter{$0.state != "delivered"}.prefix(30)) { item in
                        HStack { Text(String(item.eventID.prefix(8)));Spacer();Text(Runtime.stateLabel(item.state))
                            if ["failed","delivery_unknown"].contains(item.state) { Button("Ponów wiadomość…") { delivery=item } }
                        }
                    }
                }
            }
            Text("Mac musi być włączony i dostępny. Uśpienie przerywa odbiór; powiadomienia wymagają zgody iOS.").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
        .onDisappear { vaultPassphrase="" }
        .sheet(item:$selected) { task in
            VStack(alignment:.leading,spacing:12) {
                Text("Zadanie \(task.id.prefix(8))").font(.title2)
                Text(Runtime.stateLabel(task.state)).font(.headline)
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        Text("Polecenie").font(.headline)
                        Text(task.text.isEmpty ? "Treść usunięta zgodnie z retencją.":task.text)
                        Text("Odpowiedź").font(.headline)
                        Text(task.output ?? "Odpowiedź nie jest jeszcze dostępna lub została usunięta zgodnie z retencją.")
                        if let delivery=task.deliveryState { Text("Wiadomość: \(Runtime.stateLabel(delivery))") }
                        if let error=task.error { Text("Błąd: \(error)").foregroundStyle(.red) }
                        DisclosureGroup("Dane techniczne") {
                            Text("Sesja: \(task.session)\nRun: \(task.runID ?? "brak potwierdzenia")").font(.caption.monospaced())
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                }
                HStack {
                    Button("Otwórz Hermes") { runtime.openHermes() }
                    Text("BOTS → Indexa").font(.caption).foregroundStyle(.secondary)
                    Spacer();Button("Zamknij") { selected=nil }.keyboardShortcut(.cancelAction)
                }
            }.padding(24).frame(width:620,height:480)
        }
        .sheet(isPresented:$diagnostics) {
            VStack(alignment:.leading) { Text("Podgląd diagnostyki").font(.title2);Text("Bez transkrypcji, odpowiedzi i sekretów.").foregroundStyle(.secondary)
                ScrollView { Text(runtime.diagnosticText()).font(.caption.monospaced()).textSelection(.enabled) }
                HStack { Button("Zapisz…") { exportDiagnostics() };Button("Zamknij") { diagnostics=false } }
            }.padding().frame(width:620,height:420)
        }
        .confirmationDialog("Zamknąć sprawdzone operacje notatek?",isPresented:$confirmNotes) {
            Button("Potwierdzam sprawdzenie") { runtime.resolveNotes(noteReview);noteReview=[] }
        } message: { Text("Potwierdzasz sprawdzenie \(noteReview.count) operacji w folderze Indexa w Notatkach. Odblokujemy kolejne zapisy; żadna z tych operacji nie zostanie powtórzona. Zadania wymagające sprawdzenia zamknij po sprawdzeniu także ich pozostałych skutków.") }
        .confirmationDialog("Potwierdzasz ręczne sprawdzenie skutków zadania?",isPresented:Binding(get:{review != nil},set:{if !$0 { review=nil }})) {
            Button("Zamknij bez ponawiania") { if let task=review { Task { await runtime.resolve(task) } };review=nil }
        } message: { Text("Najpierw sprawdź dokładną notatkę i status Hermesa. Nie uruchomimy ponownie tego zadania.") }
        .confirmationDialog("Ponowić wiadomość?",isPresented:Binding(get:{delivery != nil},set:{if !$0 { delivery=nil }})) {
            Button("Ponów wysyłkę") { if let item=delivery { Task { await runtime.retry(item) } };delivery=nil }
        } message: { Text("Ponowienie używa tego samego identyfikatora wiadomości Matrix i nie uruchamia ponownie zadania Hermesa.") }
    }
    private func exportDiagnostics() {
        let panel=NSSavePanel();panel.nameFieldStringValue="indexa-diagnostics.txt"
        if panel.runModal() == .OK,let url=panel.url { do { try runtime.diagnosticText().write(to:url,atomically:true,encoding:.utf8) } catch { runtime.notice=Runtime.message(error) } }
    }
}

struct SettingsView:View {
    @ObservedObject var runtime:Runtime
    @ObservedObject private var updater=Updater.shared
    @State private var password=""
    @State private var copiedField=""
    @State private var showQR=false
    @State private var trust:MatrixDevice?
    @State private var secret=""
    @State private var showSecret=false
    @State private var signed=true
    @State private var contentDays=7
    @State private var metadataDays=30
    @State private var confirmReconnect=false
    @State private var confirmNotification=false
    @State private var confirmServe=false
    @State private var matrixToken=""
    @State private var matrixPickle=""
    @State private var matrixPassword=""
    var body:some View {
        TabView {
            Form {
                if runtime.vaultUnlocked && runtime.matrixCredentialsMissing {
                    Section("Dane Matrix do nowego sejfu") {
                        Text("Dane muszą odpowiadać istniejącej sesji bota. Nie tworzymy zamiennych kluczy ani nie odczytujemy pęku kluczy. Jeśli ich nie masz, konfiguracja Matrix wymaga osobnego przygotowania.").font(.caption)
                        SecureField("Token sesji bota Matrix",text:$matrixToken)
                        SecureField("Klucz lokalnego magazynu szyfrowania",text:$matrixPickle)
                        SecureField("Hasło konta właściciela (opcjonalnie)",text:$matrixPassword)
                        Button("Zapisz w sejfie") {
                            let token=matrixToken,pickle=matrixPickle,password=matrixPassword
                            matrixToken="";matrixPickle="";matrixPassword=""
                            Task { await runtime.saveMatrixCredentials(token:token,pickle:pickle,ownerPassword:password) }
                        }.disabled(matrixToken.isEmpty || matrixPickle.isEmpty)
                    }
                }
                Section("Element X na iPhonie") {
                    Button("Zaloguj Element X kodem QR") { showQR=true }
                        .buttonStyle(.borderedProminent).disabled(!runtime.matrixQRAvailable)
                    if !runtime.matrixQRAvailable { Text("Logowanie QR będzie dostępne po uruchomieniu lokalnego serwera.").font(.caption) }
                    Text("Włącz Tailscale na iPhonie. W Element X wybierz logowanie kodem QR. Dane do logowania hasłem znajdziesz poniżej.").foregroundStyle(.secondary)
                    LabeledContent("Serwer") {
                        HStack {
                            Text(runtime.matrixHomeserver).textSelection(.enabled)
                            copyButton("Kopiuj adres",enabled:!runtime.matrixHomeserver.isEmpty) { runtime.matrixHomeserver }
                        }
                    }
                    LabeledContent("Konto") {
                        HStack {
                            Text(runtime.matrixOwner).textSelection(.enabled)
                            copyButton("Kopiuj konto",enabled:!runtime.matrixOwner.isEmpty) { runtime.matrixOwner }
                        }
                    }
                    HStack {
                        Button(password.isEmpty ? "Pokaż hasło do logowania":"Ukryj hasło") { password=password.isEmpty ? runtime.ownerPassword():"" }
                        copyButton("Kopiuj hasło",enabled:runtime.vaultUnlocked,sensitive:true) { runtime.ownerPassword() }
                    }
                    if !password.isEmpty { Text(password).font(.caption.monospaced()).textSelection(.enabled) }
                    Text(runtime.matrixStatus)
                    Button("Wyślij test powiadomienia…") { confirmNotification=true }.disabled(!runtime.paired)
                }
                Section("Urządzenia właściciela") {
                    Text("Po zalogowaniu zatwierdź tylko urządzenie, którego identyfikator sprawdzisz w ustawieniach sesji Element X.").font(.caption)
                    Button("Odśwież urządzenia") { Task { await runtime.refreshDevices() } }
                    ForEach(runtime.matrixDevices) { device in
                        VStack(alignment:.leading) {
                            Text(device.name+" · "+device.id).textSelection(.enabled)
                            Text(device.key).font(.caption.monospaced()).textSelection(.enabled)
                            if device.verified { Text("Zatwierdzone").foregroundStyle(.secondary) }
                            else { Button("Zatwierdź urządzenie…") { trust=device } }
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Matrix",systemImage:"bubble.left.and.bubble.right") }
            Form {
                Section("Webhook Pebble") {
                    Text("Double click & hold → Webhook only → Transcription only").font(.callout)
                    Text(runtime.webhookURL.isEmpty ? "Adres pojawi się po połączeniu Tailscale.":runtime.webhookURL).textSelection(.enabled)
                    copyButton("Kopiuj adres webhooka",enabled:!runtime.webhookURL.isEmpty) { runtime.webhookURL }
                    Toggle("Weryfikuj podpisy Pebble (Sign requests)",isOn:$signed)
                    Text(signed ? "Włącz Sign requests na iPhonie i wprowadź wspólny sekret.":"Tryb starszego Pebble: ustaw Authorization: Bearer <sekret>. Nie jest fallbackiem po błędnym podpisie.").font(.caption)
                    Button(showSecret ? "Ukryj sekret":"Pokaż sekret do konfiguracji iPhone’a") { showSecret.toggle();secret=showSecret ? runtime.onboardingSecret():"" }
                    copyButton("Kopiuj sekret Pebble",enabled:runtime.vaultUnlocked,sensitive:true) { runtime.onboardingSecret() }
                    if showSecret { Text(secret).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("Send test event sprawdza odbiór bez uruchamiania Hermesa.").font(.caption)
                }
                Section("Tailscale") {
                    Text(runtime.tailscaleStatus)
                    HStack { Button("Odśwież") { Task { await runtime.refreshTailscale() } }
                        Button(runtime.serveEnabled ? "Wyłącz Serve":"Włącz prywatny Serve…") { if runtime.serveEnabled { Task { await runtime.setServe(false) } } else { confirmServe=true } }
                    }
                }
                Button("Zapisz ustawienia webhooka") { save() }
            }.formStyle(.grouped).tabItem { Label("Pierścień",systemImage:"waveform") }
            Form {
                Section("Aktualizacje") {
                    Button("Sprawdź aktualizacje…") { updater.checkForUpdates() }
                    Text(updater.status).font(.caption)
                }
                Section("Działanie") {
                    Toggle("Uruchamiaj przy logowaniu",isOn:Binding(get:{runtime.loginEnabled},set:{runtime.setLogin($0)}))
                    Text("Zamknięcie okna zostawia aplikację w pasku menu. Zakończ zatrzymuje odbiór.").font(.caption)
                    Button("Połącz ponownie Hermes i Matrix…") { confirmReconnect=true }.disabled(runtime.restarting)
                }
                Section("Hermes · profil indexa") {
                    Button("Otwórz Hermes") { runtime.openHermes() }
                    Text("Model i serwery MCP konfigurujesz poniższymi poleceniami w Terminalu. Zmiany dotyczą profilu indexa.").font(.caption)
                    copyButton("Kopiuj polecenie: model",enabled:true) { "~/.local/bin/hermes -p indexa model" }
                    copyButton("Kopiuj polecenie: MCP",enabled:true) { "~/.local/bin/hermes -p indexa mcp" }
                    Button("Otwórz plik persony SOUL.md") {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/profiles/indexa/SOUL.md"))
                    }
                    Text("Po zmianie ustawień wybierz ponowne połączenie usług. Instrukcje zadań Indexy nadal obowiązują.").font(.caption)
                }
                Section("Prywatność i historia") {
                    Stepper("Treść lokalnej kolejki: \(contentDays) dni",value:$contentDays,in:1...365)
                    Stepper("Metadane kolejki: \(metadataDays) dni",value:$metadataDays,in:1...3650)
                    Text("Ta retencja dotyczy wyłącznie lokalnej kolejki Indexy. Nie usuwa historii Hermesa, wiadomości Matrix ani notatek. Aktywne zadania i niedostarczone odpowiedzi pozostają do wyjaśnienia.").font(.caption)
                    Button("Zapisz retencję") { save() }
                }
            }.formStyle(.grouped).tabItem { Label("Aplikacja",systemImage:"gear") }
        }.padding(12)
        .sheet(isPresented:$showQR) { QRLoginView(runtime:runtime) }
        .onAppear { signed=runtime.config.signedWebhooks;contentDays=runtime.config.contentRetentionDays;metadataDays=runtime.config.metadataRetentionDays }
        .onDisappear { secret="";showSecret=false;password="";matrixToken="";matrixPickle="";matrixPassword="" }
        .safeAreaInset(edge:.bottom) { if !runtime.notice.isEmpty { Text(runtime.notice).font(.caption).padding(12).frame(maxWidth:.infinity,alignment:.leading) } }
        .confirmationDialog("Zatwierdzić dostęp tego urządzenia do odpowiedzi Indexa?",isPresented:Binding(get:{trust != nil},set:{if !$0 { trust=nil }})) {
            Button("Zatwierdź sprawdzone urządzenie") { if let device=trust { Task { await runtime.trustDevice(device) } };trust=nil }
        } message: { Text("Porównaj identyfikator i klucz z zaufanym urządzeniem. Nie zatwierdzaj nieznanych sesji.") }
        .confirmationDialog("Uruchomić ponownie lokalne usługi?",isPresented:$confirmReconnect) {
            Button("Uruchom ponownie") { Task { await runtime.reconnect() } }
        } message: { Text("Trwające zadanie może zostać przerwane i wymagać sprawdzenia skutków. Rozmowy i konto pozostaną zachowane.") }
        .confirmationDialog("Wysłać test na Matrix?",isPresented:$confirmNotification) { Button("Wyślij test") { Task { await runtime.testNotification() } } }
        .confirmationDialog("Udostępnić odbiornik w prywatnym Tailscale?",isPresented:$confirmServe) { Button("Włącz Serve") { Task { await runtime.setServe(true) } } } message: { Text("Dostęp wymaga aktywnego Tailscale na iPhonie. Udostępniamy webhook i prosty health; API Hermesa pozostaje na Macu.") }
    }
    private func copyButton(_ title:String,enabled:Bool,sensitive:Bool=false,value:@escaping ()->String) -> some View {
        Button {
            let text=value()
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(text,forType:.string) {
                copiedField=title
                let change=NSPasteboard.general.changeCount
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds:2_000_000_000)
                    if copiedField == title { copiedField="" }
                    if sensitive {
                        try? await Task.sleep(nanoseconds:58_000_000_000)
                        if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
                    }
                }
                if sensitive { runtime.notice="Skopiowano sekret. Schowek zostanie wyczyszczony po minucie, jeśli nie skopiujesz czegoś innego." }
            }
        } label: {
            Label(copiedField == title ? "Skopiowano":title,systemImage:copiedField == title ? "checkmark":"doc.on.doc")
        }.disabled(!enabled)
    }
    private func save() { var config=runtime.config;config.signedWebhooks=signed;config.contentRetentionDays=contentDays;config.metadataRetentionDays=metadataDays;Task { await runtime.saveSettings(config) } }
}
