import SwiftUI
import AppKit
import IndexaCore

struct MenuView:View {
    @ObservedObject var runtime:Runtime
    @State private var confirmReconnect=false
    var body:some View {
        Text("Indexa").font(.headline)
        Text(runtime.summary)
        Button("Otwórz Indexa") { AppWindow.shared.show() }.keyboardShortcut("o")
        Button("Ustawienia…") { AppWindow.shared.show(.settings) }
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

struct MainView:View {
    @ObservedObject var runtime:Runtime
    @ObservedObject private var navigation=AppWindow.shared
    private var selectedPage: AppPage { navigation.page == .activity ? .dashboard : navigation.page == .pebble || navigation.page == .diagnostics ? .settings : navigation.page }
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:6) {
                ForEach([AppPage.dashboard, .integrations, .matrix, .settings],id:\.self) { page in
                    Button { navigation.page=page } label: {
                        Label(page.title,systemImage:page.symbol)
                            .padding(.horizontal,10).padding(.vertical,8)
                            .background(selectedPage == page ? Color.accentColor.opacity(0.15):.clear,in:RoundedRectangle(cornerRadius:7))
                    }.buttonStyle(.plain).accessibilityAddTraits(selectedPage == page ? [.isSelected]:[])
                }
                Spacer(minLength:0)
            }.padding(12)
            Divider()
            if navigation.page == .pebble || navigation.page == .diagnostics || navigation.page == .activity {
                HStack {
                    Button { navigation.page = navigation.page == .activity ? .dashboard : .settings } label: { Label(navigation.page == .activity ? "Start" : "Ustawienia", systemImage: "chevron.left") }
                    Spacer()
                    Text(navigation.page.title).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.top, 12)
            }
            Group {
                if navigation.page == .dashboard { Dashboard(runtime:runtime) }
                else if navigation.page == .activity { TaskActivityView(runtime:runtime) }
                else if navigation.page == .integrations { IntegrationsView(runtime:runtime) }
                else if navigation.page == .diagnostics { DiagnosticsView(runtime:runtime) }
                else { SettingsView(runtime:runtime,page:navigation.page) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            Divider()
            ConnectionFooter(runtime: runtime)
        }.frame(minWidth:800,minHeight:650)
    }
}

private struct ConnectionFooter: View {
    @ObservedObject var runtime: Runtime
    var body: some View {
        HStack(spacing: 20) {
            ConnectionBadge(name: "Hermes", connected: runtime.hermesConnected, detail: runtime.hermesStatus)
            ConnectionBadge(name: "Tailscale", connected: runtime.tailscaleConnected, detail: runtime.tailscaleStatus,
                            warning: runtime.tailscaleStatus.contains("UWAGA"))
            ConnectionBadge(name: "Matrix", connected: runtime.matrixConnected, detail: runtime.matrixStatus)
            Spacer(minLength: 0)
            Button { AppWindow.shared.page = .diagnostics } label: { Image(systemName: "stethoscope") }
                .buttonStyle(.plain).help("Diagnostyka").accessibilityLabel("Otwórz diagnostykę")
        }.font(.caption).padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
    }
}

private struct ConnectionBadge: View {
    let name: String
    let connected: Bool
    let detail: String
    var warning = false
    @State private var expanded = false
    private var waiting: Bool { detail.hasPrefix("Uruchamianie") || detail.hasPrefix("Sprawdzanie") }
    private var state: String { warning ? "Uwaga" : connected ? "Połączony" : waiting ? "Łączenie…" : "Brak połączenia" }
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: warning ? "exclamationmark.circle.fill" : connected ? "checkmark.circle.fill" : waiting ? "clock" : "exclamationmark.circle.fill")
                    .foregroundStyle(warning ? Color.orange : connected ? .green : waiting ? .secondary : .orange)
                Text(name).fontWeight(.medium)
                Text(state).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(detail).accessibilityLabel("\(name): \(state). Szczegóły połączenia")
            .popover(isPresented: $expanded, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(name).font(.headline)
                    Text(detail).textSelection(.enabled)
                    Button("Diagnostyka") { expanded = false; AppWindow.shared.page = .diagnostics }
                }.padding(18).frame(width: 300, alignment: .leading)
            }
    }
}

struct Dashboard: View {
    @ObservedObject var runtime: Runtime
    private var currentTasks: [TaskRecord] {
        runtime.tasks.filter { ["queued", "submitting", "running", "waiting_for_approval", "stopping"].contains($0.state) }
    }
    private var needsDecision: Bool {
        runtime.vaultNeedsPassphrase || !runtime.pendingNoteWrites.isEmpty || !runtime.approvals.isEmpty || runtime.tasks.contains { $0.state == "needs_review" }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 76, height: 76).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Indexa").font(.largeTitle.bold())
                        Text("Twój osobisty asystent").font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Co chcesz dziś załatwić?").font(.title2.bold())
                    Text("Napisz w Hermesie na Macu lub w Element X na telefonie. Indexa może sprawdzić kalendarz, zapisać notatkę albo dodać przypomnienie.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button { runtime.openHermes() } label: { Label("Otwórz rozmowę", systemImage: "bubble.left.and.bubble.right") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Dostęp do aplikacji") { AppWindow.shared.page = .integrations }.controlSize(.large)
                    }
                }
                if runtime.paused {
                    HStack {
                        Label("Nowe zadania są wstrzymane", systemImage: "pause.circle")
                        Spacer()
                        Button("Wznów") { Task { await runtime.togglePause() } }.disabled(!runtime.ready)
                    }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                if needsDecision {
                    HStack {
                        Label(runtime.vaultNeedsPassphrase ? "Odblokuj Indexę, aby kontynuować" : "Potrzebna Twoja decyzja", systemImage: "hand.raised")
                        Spacer()
                        Button("Sprawdź") { AppWindow.shared.page = .activity }
                    }.padding(16).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
                if runtime.outbox.contains(where: { ["failed", "delivery_unknown"].contains($0.state) }) {
                    HStack {
                        Label("Nie udało się dostarczyć odpowiedzi", systemImage: "exclamationmark.bubble")
                        Spacer()
                        Button("Sprawdź") { AppWindow.shared.page = .diagnostics }
                    }.padding(16).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
                if !currentTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Teraz").font(.headline)
                        ForEach(currentTasks.prefix(3)) { task in
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.text.isEmpty ? "Przetwarzanie polecenia" : task.text).lineLimit(2)
                                    Text(Runtime.stateLabel(task.state)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        if currentTasks.count > 3 { Text("Pozostałe w kolejce: \(currentTasks.count - 3)").font(.caption).foregroundStyle(.secondary) }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                Button { AppWindow.shared.page = .activity } label: { Label("Historia i szczegóły zadań", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.link)
            }.padding(32).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

struct TaskActivityView:View {
    @ObservedObject var runtime:Runtime
    @State private var selected:TaskRecord?
    @State private var review:TaskRecord?
    @State private var noteReview=[String]()
    @State private var confirmNotes=false
    @State private var vaultPassphrase=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:6) { Text("Zadania").font(.largeTitle.bold());Text("Historia poleceń i sprawy wymagające Twojej decyzji.").foregroundStyle(.secondary) }
                Spacer()
            }
            Label(runtime.summary,systemImage:runtime.statusSymbol).font(.title2)
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
                Spacer()
            }
            if let selected {
                taskDetails(runtime.tasks.first(where:{$0.id == selected.id}) ?? selected)
            } else {
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
                            VStack(alignment:.leading) { Text(task.text.isEmpty ? "Zadanie bez zachowanej treści" : task.text).lineLimit(2);Text(Date(timeIntervalSince1970:task.created),style:.time).font(.caption).foregroundStyle(.secondary) }
                            Spacer();Text(Runtime.stateLabel(task.state)).font(.callout)
                            Button("Szczegóły") { selected=task }
                            if task.state == "needs_review" { Button("Sprawdziłem…") { review=task } }
                        }
                    }
                }

            }
            }
        }.padding(24)
        .onDisappear { vaultPassphrase="" }
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "indexa" { vaultPassphrase="" }
        }
        .confirmationDialog("Zamknąć sprawdzone operacje notatek?",isPresented:$confirmNotes) {
            Button("Potwierdzam sprawdzenie") { runtime.resolveNotes(noteReview);noteReview=[] }
        } message: { Text("Potwierdzasz sprawdzenie \(noteReview.count) operacji w folderze Indexa w Notatkach. Odblokujemy kolejne zapisy; żadna z tych operacji nie zostanie powtórzona. Zadania wymagające sprawdzenia zamknij po sprawdzeniu także ich pozostałych skutków.") }
        .confirmationDialog("Potwierdzasz ręczne sprawdzenie skutków zadania?",isPresented:Binding(get:{review != nil},set:{if !$0 { review=nil }})) {
            Button("Zamknij bez ponawiania") { if let task=review { Task { await runtime.resolve(task) } };review=nil }
        } message: { Text("Najpierw sprawdź dokładną notatkę i status Hermesa. Nie uruchomimy ponownie tego zadania.") }

    }
    private func taskDetails(_ task:TaskRecord) -> some View {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Button { selected=nil } label: { Label("Wróć do zadań",systemImage:"chevron.left") }
                    Spacer();Text("Zadanie \(task.id.prefix(8))").font(.title2)
                }
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
                    Spacer()
                }
            }.padding(16).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }
}

struct DiagnosticsView:View {
    @ObservedObject var runtime:Runtime
    @State private var delivery: OutboxItem?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Diagnostyka").font(.title2)
            Text("Bez transkrypcji, odpowiedzi i sekretów.").foregroundStyle(.secondary)
            DisclosureGroup("Kolejka dostarczenia wiadomości") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let pending = runtime.outbox.filter { $0.state != "delivered" }
                        if pending.isEmpty { Text("Wszystkie odpowiedzi zostały dostarczone.").foregroundStyle(.secondary) }
                        ForEach(pending.prefix(30)) { item in
                            HStack {
                                Text(String(item.eventID.prefix(8))).font(.caption.monospaced())
                                Spacer()
                                Text(Runtime.stateLabel(item.state))
                                if ["failed", "delivery_unknown"].contains(item.state) {
                                    Button("Ponów wiadomość…") { delivery = item }
                                }
                            }
                        }
                        if pending.count > 30 { Text("Pokazujemy pierwsze 30 oczekujących wiadomości.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 8)
                }.frame(maxHeight: 180)
            }
            ScrollView {
                Text(runtime.diagnosticText()).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
            Button("Zapisz diagnostykę…") { exportDiagnostics() }
        }.padding(24)
        .confirmationDialog("Ponowić wiadomość?", isPresented: Binding(get: { delivery != nil }, set: { if !$0 { delivery = nil } })) {
            Button("Ponów wysyłkę") { if let item = delivery { Task { await runtime.retry(item) } }; delivery = nil }
        } message: { Text("Ponowienie zachowuje identyfikator wiadomości i nie uruchamia ponownie zadania Hermesa.") }
    }
    private func exportDiagnostics() {
        let panel=NSSavePanel();panel.nameFieldStringValue="indexa-diagnostics.txt"
        if panel.runModal() == .OK,let url=panel.url { do { try runtime.diagnosticText().write(to:url,atomically:true,encoding:.utf8) } catch { runtime.notice=Runtime.message(error) } }
    }
}

struct SettingsView:View {
    @ObservedObject var runtime:Runtime
    let page:AppPage
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
    @State private var matrixToken=""
    @State private var matrixPickle=""
    @State private var matrixPassword=""
    @State private var loaded=false
    var body:some View {
        Group {
            if page == .matrix && showQR {
                ScrollView { QRLoginView(runtime:runtime,onClose:{ showQR=false }).frame(maxWidth:.infinity) }
            } else if page == .matrix {
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
                    Text("Włącz Tailscale na iPhonie i wybierz w Element X logowanie kodem QR.").foregroundStyle(.secondary)
                    DisclosureGroup("Logowanie hasłem") {
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
                    }
                    Button("Wyślij test powiadomienia…") { confirmNotification=true }.disabled(!runtime.paired)
                }
                Section { DisclosureGroup("Urządzenia właściciela") {
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
                } }
            }.formStyle(.grouped)
            } else if page == .pebble {
            Form {
                Section("Webhook Pebble") {
                    Text("Hold & talk lub Double click & hold → Webhook only → Transcription only").font(.callout)
                    Text("Skonfiguruj używany gest, włącz jego webhook i zapisz ustawienia w Pebble. Każdy gest ma osobną konfigurację.").font(.caption)
                    Text("Webhook korzysta z tego samego prywatnego połączenia HTTPS co Matrix, na porcie 8443.").font(.callout)
                    Text(runtime.webhookURL.isEmpty ? "Adres pojawi się, gdy prywatne połączenie na 8443 będzie dostępne.":runtime.webhookURL).textSelection(.enabled)
                    copyButton("Kopiuj adres webhooka",enabled:!runtime.webhookURL.isEmpty) { runtime.webhookURL }
                    Toggle("Weryfikuj podpisy Pebble (Sign requests)",isOn:$signed)
                    Text(signed ? "W Pebble włącz Sign requests i wklej sekret z Indexy. Dodatkowe nagłówki nie są potrzebne.":"Tryb starszego Pebble: ustaw Authorization: Bearer <sekret>. Nie jest fallbackiem po błędnym podpisie.").font(.caption)
                    Button(showSecret ? "Ukryj sekret":"Pokaż sekret do konfiguracji iPhone’a") { showSecret.toggle();secret=showSecret ? runtime.onboardingSecret():"" }
                    copyButton("Kopiuj sekret Pebble",enabled:runtime.vaultUnlocked,sensitive:true) { runtime.onboardingSecret() }
                    if showSecret { Text(secret).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("Send test event sprawdza odbiór bez uruchamiania Hermesa. Udany test nie oznacza, że konfiguracja gestu została zapisana i włączona.").font(.caption)
                }
                Section("Tailscale") {
                    Text(runtime.tailscaleStatus)
                    Text("Tailscale musi być połączony także na iPhonie. Indexa tylko odczytuje stan połączenia; nie zmienia ustawień VPN ani DNS.").font(.caption)
                    Button("Odśwież stan") { Task { await runtime.refreshTailscale() } }
                }
                Button("Zapisz ustawienia webhooka") { save() }
            }.formStyle(.grouped)
            } else {
            Form {
                Section("Aktualizacje") {
                    Button("Sprawdź aktualizacje…") { updater.checkForUpdates() }
                    Text(updater.status).font(.caption)
                }
                Section("Działanie") {
                    Toggle("Uruchamiaj przy logowaniu",isOn:Binding(get:{runtime.loginEnabled},set:{runtime.setLogin($0)}))
                    Text("Zamknięcie okna zostawia aplikację w pasku menu. Zakończ zatrzymuje odbiór.").font(.caption)
                    Button("Skonfiguruj pierścień Pebble") { AppWindow.shared.page = .pebble }
                }
                Section { DisclosureGroup("Ustawienia Hermesa") {
                    Button("Otwórz Hermes") { runtime.openHermes() }
                    Text("Narzędzia Indexy włączysz w Integracjach. Tutaj zmienisz model, personę i zewnętrzne MCP profilu indexa.").font(.caption)
                    copyButton("Kopiuj polecenie: model",enabled:true) { "~/.local/bin/hermes -p indexa model" }
                    copyButton("Kopiuj polecenie: MCP",enabled:true) { "~/.local/bin/hermes -p indexa mcp" }
                    Button("Otwórz plik persony SOUL.md") {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/profiles/indexa/SOUL.md"))
                    }
                    Text("Po zmianie ustawień wybierz ponowne połączenie usług. Instrukcje zadań Indexy nadal obowiązują.").font(.caption)
                } }
                Section { DisclosureGroup("Prywatność i historia") {
                    Stepper("Treść lokalnej kolejki: \(contentDays) dni",value:$contentDays,in:1...365)
                    Stepper("Metadane kolejki: \(metadataDays) dni",value:$metadataDays,in:1...3650)
                    Text("Retencja obejmuje lokalną kolejkę i załączniki Indexy. Nie usuwa historii Hermesa, wiadomości Matrix ani notatek. Pliki aktywnych zadań i niedostarczonych odpowiedzi pozostają do wyjaśnienia.").font(.caption)
                    Button("Zapisz retencję") { save() }
                } }
                Section { DisclosureGroup("Rozwiązywanie problemów") {
                    Button("Połącz ponownie Hermes i Matrix…") { confirmReconnect=true }.disabled(runtime.restarting)
                    Button("Otwórz diagnostykę") { AppWindow.shared.page = .diagnostics }
                } }
            }.formStyle(.grouped)
            }
        }.padding(12)
        .onAppear {
            guard !loaded else { return };loaded=true
            signed=runtime.config.signedWebhooks;contentDays=runtime.config.contentRetentionDays;metadataDays=runtime.config.metadataRetentionDays
        }
        .onChange(of:page) { _,_ in showQR=false;clearSecrets() }
        .onDisappear { clearSecrets() }
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.willCloseNotification)) { notification in
            guard (notification.object as? NSWindow)?.identifier?.rawValue == "indexa" else { return }
            showQR=false;clearSecrets()
        }
        .safeAreaInset(edge:.bottom) { if !runtime.notice.isEmpty { Text(runtime.notice).font(.caption).padding(12).frame(maxWidth:.infinity,alignment:.leading) } }
        .confirmationDialog("Zatwierdzić dostęp tego urządzenia do odpowiedzi Indexa?",isPresented:Binding(get:{trust != nil},set:{if !$0 { trust=nil }})) {
            Button("Zatwierdź sprawdzone urządzenie") { if let device=trust { Task { await runtime.trustDevice(device) } };trust=nil }
        } message: { Text("Porównaj identyfikator i klucz z zaufanym urządzeniem. Nie zatwierdzaj nieznanych sesji.") }
        .confirmationDialog("Uruchomić ponownie lokalne usługi?",isPresented:$confirmReconnect) {
            Button("Uruchom ponownie") { Task { await runtime.reconnect() } }
        } message: { Text("Trwające zadanie może zostać przerwane i wymagać sprawdzenia skutków. Rozmowy i konto pozostaną zachowane.") }
        .confirmationDialog("Wysłać test na Matrix?",isPresented:$confirmNotification) { Button("Wyślij test") { Task { await runtime.testNotification() } } }
    }
    private func clearSecrets() { secret="";showSecret=false;password="";matrixToken="";matrixPickle="";matrixPassword="" }
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
