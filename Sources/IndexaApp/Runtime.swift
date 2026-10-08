import AppKit
import SwiftUI
import ServiceManagement
import Vapor
import IndexaCore
import Darwin

@MainActor
final class Runtime:ObservableObject {
    static let shared=Runtime()
    @Published var config=Configuration()
    @Published var receiverStatus="Uruchamianie…"
    @Published var hermesStatus="Uruchamianie…"
    @Published var matrixStatus="Uruchamianie Matrix…"
    @Published var tailscaleStatus="Sprawdzanie…"
    @Published var webhookURL=""
    @Published var serveEnabled=false
    @Published var paired=false
    @Published var paused=false
    @Published var tasks=[TaskRecord]()
    @Published var outbox=[OutboxItem]()
    @Published var approvals=[ApprovalRecord]()
    @Published var pendingNoteWrites=[String]()
    private let profileHome=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/profiles/indexa")
    @Published var notice=""
    @Published var ready=false
    @Published var loginEnabled=SMAppService.mainApp.status == .enabled
    var db:Database?
    private var app:Application?
    private var agent:AgentWorker?
    private var receiver:MatrixReceiver?
    private var matrix:MatrixClient?
    private var matrixProcess:Process?
    @Published var matrixHomeserver=""
    @Published var matrixOwner=""
    @Published var matrixDevices=[MatrixDevice]()
    @Published var matrixQRAvailable=false
    private var outboxWorker:OutboxWorker?
    private var loops=[Task<Void,Never>]()
    private var gateway:Process?
    private var lockFD:Int32 = -1
    private let secrets=SecretStore()
    @Published var vaultUnlocked=false
    @Published var vaultNeedsPassphrase=false
    @Published var matrixCredentialsMissing=true
    private let tailscale=TailscaleClient()
    private var matrixFailures=0
    private var hermesFailures=0
    private var starting=false
    @Published var restarting=false
    @Published var matrixConnected=false
    @Published var hermesConnected=false
    @Published var tailscaleConnected=false
    var hasActiveTask:Bool { tasks.contains { ["submitting","running","waiting_for_approval","stopping"].contains($0.state) } }
    var summary:String {
        if restarting { return "Łączenie ponownie…" }
        if !ready || !matrixConnected || !hermesConnected || tasks.contains(where:{$0.state == "needs_review"}) || outbox.contains(where:{["failed","delivery_unknown"].contains($0.state)}) || !pendingNoteWrites.isEmpty || approvals.contains(where:{$0.state == "pending"}) { return "Wymaga uwagi" }
        if paused { return "Wstrzymana" }
        return hasActiveTask ? "Pracuje" : "Gotowa"
    }
    var statusSymbol:String { summary == "Gotowa" ? "checkmark.circle.fill" : (summary == "Pracuje" ? "waveform.circle.fill" : "exclamationmark.circle.fill") }


    func start() async {
        guard !starting,!ready else { return };starting=true;defer { starting=false }
        do {
            try secrets.openAutomatically()
            vaultUnlocked=true;vaultNeedsPassphrase=false
            _ = try secrets.getOrCreate(.pebbleSigning)
            _ = try secrets.getOrCreate(.hermesAPI)
            _ = try secrets.getOrCreate(.matrixTransport)
            matrixCredentialsMissing=try secrets.read(.matrixBotToken) == nil || secrets.read(.matrixPickle) == nil
            _ = try requiredSecret(.matrixBotToken)
            _ = try requiredSecret(.matrixPickle)
            config=try Configuration.load()
            try config.save()
            lockFD=open(Configuration.directory.appendingPathComponent("instance.lock").path,O_CREAT|O_RDWR,0o600)
            guard lockFD >= 0,flock(lockFD,LOCK_EX|LOCK_NB) == 0 else { throw IndexaError("indexa_already_running") }
            try await StackCompatibility.prepare()
            let database=try Database(url:Configuration.directory.appendingPathComponent("bridge.sqlite"));db=database
            try await database.recover()
            let webhookSecret=try secrets.getOrCreate(.pebbleSigning),key=try secrets.getOrCreate(.hermesAPI)
            let hermes=HermesClient(baseURL:URL(string:config.hermesURL)!,key:key)
            agent=AgentWorker(database:database,hermes:hermes)
            await agent?.setPaused(paused)
            try await startIngress(secret:webhookSecret)
            try launchGateway(key:key)
            try launchMatrix()
            try setupMatrix()
            ready=true
            // Each service has its own loop: a Matrix outage cannot stall Hermes or the dashboard.
            loops.append(poll(every:2) { await self.pollMatrix() })
            loops.append(poll(every:2) { await self.pollHermes(hermes) })
            loops.append(poll(every:2) {
                do { try await self.outboxWorker?.tick() } catch { if !Task.isCancelled { self.notice=Self.message(error) } }
            })
            loops.append(poll(every:2) { await self.refreshRecords() })
            loops.append(Task { [weak self] in
                var iteration=0
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refreshTailscale()
                    if iteration % 360 == 0 { try? await database.prune(contentDays:self.config.contentRetentionDays,metadataDays:self.config.metadataRetentionDays) }
                    iteration+=1
                    do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { return }
                }
            })
        } catch {
            vaultNeedsPassphrase=(error as? IndexaError)?.code == "vault_existing_password_required"
            await shutdown()
            receiverStatus="Nie uruchomiono";hermesStatus="Zatrzymany";matrixStatus="Zatrzymany"
            tailscaleStatus="Nie sprawdzono";notice=Self.message(error)
        }
    }
    func unlockVault(passphrase:String) async {
        do {
            try secrets.unlock(passphrase:passphrase)
            vaultUnlocked=true;vaultNeedsPassphrase=false
            await start()
        } catch { notice=Self.message(error) }
    }
    func saveMatrixCredentials(token:String,pickle:String,ownerPassword:String) async {
        do {
            guard !ready,matrixCredentialsMissing else { throw IndexaError("matrix_credentials_already_configured") }
            guard token.utf8.count >= 16,pickle.utf8.count >= 16 else { throw IndexaError("matrix_credentials_invalid") }
            var values:[SecretName:String]=[.matrixBotToken:token,.matrixPickle:pickle]
            if !ownerPassword.isEmpty { values[.matrixOwnerPassword]=ownerPassword }
            try secrets.write(values)
            matrixCredentialsMissing=false
            notice="Dane zapisane w sejfie. Możesz wybrać Połącz ponownie."
        } catch { notice=Self.message(error) }
    }
    private func startIngress(secret:String) async throws {
        guard let db else { throw IndexaError("database_unavailable") }
        let server=try await Application.make(.init(name:"production",arguments:["Indexa"]))
        do {
            try Ingress.install(on:server,database:db,configuration:config,secret:secret)
            try await server.http.server.shared.start(address:.hostname("127.0.0.1",port:config.port))
            app=server;receiverStatus="Nasłuchuje na 127.0.0.1:\(config.port)"
        } catch { try? await server.asyncShutdown();throw error }
    }
    private func launchGateway(key:String) throws {
        if gateway?.isRunning == true { return }
        let home=FileManager.default.homeDirectoryForCurrentUser
        let executable=home.appendingPathComponent(".local/bin/hermes")
        let profile=home.appendingPathComponent(".hermes/profiles/indexa")
        guard FileManager.default.fileExists(atPath:profile.appendingPathComponent("config.yaml").path) else { throw IndexaError("indexa_hermes_profile_missing") }
        let process=Process()
        process.executableURL=executable;process.arguments=["-p","indexa","gateway","run"]
        var environment=Self.childEnvironment()
        environment["HERMES_HOME"]=profile.path
        environment["HERMES_DISABLE_LAZY_INSTALLS"]="1"
        environment["API_SERVER_KEY"]=key
        environment["API_SERVER_HOST"]="127.0.0.1"
        environment["API_SERVER_PORT"]=String(URLComponents(string:config.hermesURL)!.port!)
        environment.removeValue(forKey:"TELEGRAM_BOT_TOKEN")
        process.environment=environment
        process.currentDirectoryURL=profile
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();gateway=process
    }
    func reconnect() async {
        guard !restarting,!starting else { return }
        restarting=true;defer { restarting=false }
        guard await shutdown() else { return }
        await start()
        if ready { notice="Usługi uruchomione ponownie. Trwa sprawdzanie połączeń." }
    }
    private func launchMatrix() throws {
        if matrixProcess?.isRunning == true { return }
        let script=Bundle.main.resourceURL!.appendingPathComponent("matrix/service.py")
        guard FileManager.default.fileExists(atPath:script.path) else { throw IndexaError("matrix_bundle_resource_missing") }
        let process=Process()
        process.executableURL=Configuration.directory.appendingPathComponent("runtime/venv/bin/python")
        process.arguments=[script.path]
        process.environment=Self.childEnvironment()
        let input=Pipe();process.standardInput=input
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        var names:[SecretName]=[.matrixTransport,.matrixBotToken,.matrixPickle]
        if try secrets.read(.matrixOwnerToken) != nil { names += [.matrixOwnerToken,.matrixOwnerPickle] }
        var credentials=[String:String]()
        for name in names {
            guard let value=try secrets.read(name) else { throw IndexaError("matrix_credentials_missing") }
            credentials[name.rawValue]=value
        }
        let payload=try JSONSerialization.data(withJSONObject:credentials)
        try process.run();matrixProcess=process
        input.fileHandleForReading.closeFile()
        try input.fileHandleForWriting.write(contentsOf:payload)
        try input.fileHandleForWriting.close()

    }
    private func setupMatrix() throws {
        guard let db,let agent else { throw IndexaError("not_ready") }
        let client=MatrixClient(key:try requiredSecret(.matrixTransport))
        matrix=client;receiver=MatrixReceiver(database:db,matrix:client,worker:agent)
        outboxWorker=OutboxWorker(database:db,matrix:client)
    }
    func ownerPassword() -> String {
        do { return try secrets.read(.matrixOwnerPassword) ?? "" } catch { notice=Self.message(error);return "" }
    }
    func pairing(_ path:String,_ body:[String:Any]? = nil) async throws -> [String:Any] {
        guard let matrix else { throw IndexaError("not_ready") }
        return try await matrix.call("qr/"+path,body)
    }
    func refreshDevices() async {
        do {
            let items=try await matrix?.call("devices")["devices"] as? [[String:Any]] ?? []
            matrixDevices=items.compactMap { value in
                guard let id=value["id"] as? String,let key=value["key"] as? String else { return nil }
                return MatrixDevice(id:id,name:value["name"] as? String ?? id,key:key,verified:value["verified"] as? Bool == true)
            }
        } catch { notice=Self.message(error) }
    }
    func trustDevice(_ device:MatrixDevice) async {
        do { _ = try await matrix?.call("trust",["id":device.id,"key":device.key]);await refreshDevices();notice="Urządzenie zatwierdzone." }
        catch { notice=Self.message(error) }
    }
    private func poll(every seconds:UInt64,action:@escaping @MainActor () async -> Void) -> Task<Void,Never> {
        Task {
            while !Task.isCancelled {
                await action()
                do { try await Task.sleep(nanoseconds:seconds*1_000_000_000) } catch { return }
            }
        }
    }
    private func pollMatrix() async {
        guard let db,let matrix else { return }
        do {
            let health=try await matrix.call("health")
            guard !Task.isCancelled else { return }
            guard let room=health["room_id"] as? String,let owner=health["owner_user"] as? String,let bot=health["bot_user"] as? String else { throw IndexaError("matrix_identity_missing") }
            try await db.bindMatrix(room:room,user:owner,bot:bot)
            matrixHomeserver=health["homeserver"] as? String ?? "";matrixOwner=owner
            matrixQRAvailable=health["qr_enabled"] as? Bool == true
            matrixFailures=0
            matrixConnected=health["ready"] as? Bool == true
            matrixStatus=matrixConnected ? "Połączony · E2EE" : "Oczekiwanie: \(health["problem"] as? String ?? "sync")"
            if matrixConnected { try await receiver?.poll() }
        } catch { if !Task.isCancelled { matrixConnected=false;matrixQRAvailable=false;matrixStatus="Brak połączenia: \(Self.message(error))";matrixFailures=min(matrixFailures+1,4);try? await Task.sleep(nanoseconds:UInt64(1 << matrixFailures)*1_000_000_000) } }
    }
    private func pollHermes(_ hermes:HermesClient) async {
        guard let db,let agent else { return }
        do {
            let caps=try await hermes.capabilities()
            guard !Task.isCancelled else { return }
            let features=caps["features"] as? [String:Any] ?? [:]
            hermesFailures=0
            hermesConnected=features["run_submission"] as? Bool == true
            hermesStatus=hermesConnected ? "API gotowe" : "API nie obsługuje zadań"
            if hermesConnected,let owner=try await db.value("owner_chat") {
                try await agent.tick(destination:owner)
                try await agent.expireApprovals()
            }
        } catch { if !Task.isCancelled { hermesConnected=false;hermesStatus="Brak potwierdzenia: \(Self.message(error))";hermesFailures=min(hermesFailures+1,4);try? await Task.sleep(nanoseconds:UInt64(1 << hermesFailures)*1_000_000_000) } }
    }
    private func refreshRecords() async {
        guard let db else { return }
        do { tasks=try await db.tasks();outbox=try await db.outbox();approvals=try await db.approvals();paired=try await db.value("owner_chat") != nil }
        catch { if !Task.isCancelled { notice=Self.message(error) } }
        do { pendingNoteWrites=try NotesRecovery.pending(profileHome:profileHome) }
        catch { if (error as? IndexaError)?.code != "notes_write_in_progress",!Task.isCancelled { notice=Self.message(error) } }
    }
    func togglePause() async { paused.toggle();await agent?.setPaused(paused) }
    func cancelActive() async { do { try await agent?.cancel();notice="Wysłano żądanie zatrzymania. Wcześniejsze efekty nie są cofane." } catch { notice=Self.message(error) } }
    func newConversation() async { notice="Indexa używa jednej wspólnej rozmowy w Hermesie i Matrixie. Napisz, od którego tematu zaczynamy." }
    func decide(_ approval:ApprovalRecord,choice:String) async {
        do { guard let owner=try await db?.value("owner_chat") else { throw IndexaError("not_paired") };try await agent?.approve(id:approval.id,owner:owner,choice:choice);notice="Decyzja zapisana." }
        catch { notice=Self.message(error) }
    }
    func resolve(_ task:TaskRecord) async {
        do {
            guard try NotesRecovery.pending(profileHome:profileHome).isEmpty else { throw IndexaError("notes_review_required") }
            try await db?.resolveReview(task.id);notice="Zamknięto po ręcznym sprawdzeniu, bez ponawiania wykonania."
        } catch { notice=Self.message(error) }
    }
    func resolveNotes(_ ids:[String]) {
        do {
            try NotesRecovery.reviewed(ids,profileHome:profileHome)
            pendingNoteWrites=try NotesRecovery.pending(profileHome:profileHome)
            notice="Sprawdzone operacje notatek zamknięte. Nie wykonano ich ponownie."
        } catch { notice=Self.message(error) }
    }

    func retry(_ item:OutboxItem) async { do { try await db?.retryDelivery(item.id);notice="Ponowienie dotyczy wyłącznie wiadomości Matrix." } catch { notice=Self.message(error) } }
    func testNotification() async {
        do { guard let owner=try await db?.value("owner_chat") else { throw IndexaError("not_paired") };try await db?.enqueue(destination:owner,body:"Indexa: test powiadomienia. Sprawdź banner i dźwięk na zablokowanym iPhonie.");notice="Test dodany do outbox." }
        catch { notice=Self.message(error) }
    }
    func refreshTailscale() async {
        do { let snapshot=try await tailscale.snapshot(port:config.port);tailscaleConnected=snapshot.online;serveEnabled=snapshot.serve;webhookURL=snapshot.webhookURL;tailscaleStatus=snapshot.online ? (snapshot.funnel ? "UWAGA: odbiornik publiczny przez Funnel" : (snapshot.serve ? "Prywatny Serve skonfigurowany":"Online · Serve wyłączony")) : snapshot.state }
        catch { tailscaleConnected=false;tailscaleStatus="Niedostępny: \(Self.message(error))";serveEnabled=false }
    }
    func setServe(_ enabled:Bool) async {
        do { guard ready else { throw IndexaError("receiver_not_ready") };try await tailscale.setServe(port:config.port,enabled:enabled);await refreshTailscale();notice=enabled ? "Prywatny Serve włączony. Tailscale musi działać na iPhonie.":"Serve wyłączony." }
        catch { notice="\(Self.message(error)). Pierwsze włączenie może wymagać włączenia HTTPS w panelu Tailscale." }
    }
    func saveSettings(_ updated:Configuration) async {
        do {
            guard ready else { throw IndexaError("receiver_not_ready") }
            try updated.validate()
            guard updated.port == config.port,updated.hermesURL == config.hermesURL else { throw IndexaError("port_change_requires_restart") }
            let restartReceiver=updated.signedWebhooks != config.signedWebhooks
            try updated.save();config=updated
            if restartReceiver,let app { await app.http.server.shared.shutdown();try await app.asyncShutdown();self.app=nil }
            if restartReceiver { try await startIngress(secret:secrets.getOrCreate(.pebbleSigning)) }
            notice="Ustawienia zapisane."
        } catch { notice=Self.message(error) }
    }
    func onboardingSecret() -> String {
        do { return try secrets.read(.pebbleSigning) ?? "" } catch { notice=Self.message(error);return "" }
    }
    func setLogin(_ enabled:Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() };loginEnabled=SMAppService.mainApp.status == .enabled }
        catch { notice=Self.message(error) }
    }
    func diagnosticText() -> String {
        "Indexa\nReceiver: \(receiverStatus)\nHermes: \(hermesStatus)\nMatrix: \(matrixStatus)\nTailscale: \(tailscaleStatus)\n" + tasks.map{"\($0.id) \($0.state) \($0.error ?? "")"}.joined(separator:"\n")
    }
    @discardableResult func shutdown() async -> Bool {
        ready=false;matrixConnected=false;hermesConnected=false;matrixQRAvailable=false
        let pending=loops;loops.removeAll()
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        if let app { await app.http.server.shared.shutdown();try? await app.asyncShutdown();self.app=nil }
        // Matrix drains its subprocesses; never start a second stack before it exits.
        let children=[gateway,matrixProcess].compactMap{$0}
        for process in children where process.isRunning { process.terminate() }
        let deadline=ContinuousClock.now.advanced(by:.seconds(60))
        while children.contains(where:{$0.isRunning}),ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds:100_000_000)
        }
        guard !children.contains(where:{$0.isRunning}) else {
            notice="Usługi nie zakończyły jeszcze pracy. Poczekaj i ponów; druga kopia nie zostanie uruchomiona."
            return false
        }
        gateway=nil;matrixProcess=nil;receiver=nil;matrix=nil;outboxWorker=nil;agent=nil
        if lockFD >= 0 { flock(lockFD,LOCK_UN);close(lockFD);lockFD = -1 }
        return true
    }
    static func stateLabel(_ state:String) -> String {
        ["queued":"W kolejce","submitting":"Przekazywanie do Hermesa","running":"W trakcie","waiting_for_approval":"Czeka na zgodę","stopping":"Zatrzymywanie","completed":"Wykonane","failed":"Błąd","cancelled":"Zatrzymane","needs_review":"Sprawdź skutki","pending":"Oczekuje","sending":"Wysyłanie","delivered":"Dostarczono","retry_wait":"Ponowi automatycznie","delivery_unknown":"Dostarczenie niepotwierdzone","resolved":"Sprawdzone","expired":"Wygasła","resolving":"Zapisywanie decyzji","unknown":"Wymaga sprawdzenia","approved":"Zgoda udzielona","denied":"Odmowa"][state] ?? state
    }
    private func requiredSecret(_ name:SecretName) throws -> String {
        guard let value=try secrets.read(name) else { throw IndexaError("required_credential_missing") }
        return value
    }
    private static func childEnvironment() -> [String:String] {
        let original=ProcessInfo.processInfo.environment
        var result=original.filter{["HOME","USER","LOGNAME","LANG","LC_ALL","TMPDIR"].contains($0.key)}
        result["PATH"]="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        result["PYTHONDONTWRITEBYTECODE"]="1"
        return result
    }
    static func message(_ error:Error) -> String {
        if let e=error as? IndexaError {
            switch e.code {
            case "notes_review_required":return "Najpierw sprawdź operacje w sekcji Notatki wymagające sprawdzenia."
            case "notes_write_in_progress":return "Trwa zapis notatki. Poczekaj na zakończenie, zanim zatwierdzisz sprawdzenie."
            case "vault_locked":return "Magazyn sekretów jest niedostępny. Spróbuj połączyć ponownie."
            case "vault_existing_password_required":return "Istniejący sejf wymaga dotychczasowego hasła; nie nadpisano jego danych."
            case "vault_invalid_local_key":return "Nie można odczytać lokalnego klucza. Nie zastępujemy go nowym, aby zachować istniejące dane."
            case "vault_passphrase_too_short":return "Użyj hasła mającego co najmniej 16 znaków, najlepiej kilku losowych słów."
            case "vault_unlock_failed":return "Nie można odblokować sejfu: błędne hasło lub uszkodzony plik."
            case "vault_in_use":return "Sejf jest już otwarty w innym procesie Indexy."
            case "required_credential_missing":return "Sejf odblokowany. Uzupełnij dane Matrix w Ustawieniach. Niczego nie pobieramy z pęku kluczy."
            default:break
            }
        }
        if let e=error as? IndexaError { return e.code }
        if let e=error as? APIError { return "API \(e.code)" }
        let e=error as NSError;return "\(e.domain) \(e.code)"
    }
}

struct MatrixDevice:Identifiable { let id:String,name:String,key:String,verified:Bool }
