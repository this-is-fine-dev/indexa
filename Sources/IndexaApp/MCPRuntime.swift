import AppKit
import CryptoKit
import Foundation
import IndexaCore
import Vapor

extension Runtime {
    func startMCP() async {
        guard mcpServer == nil else { return }
        do {
            try mcpSecrets.openAutomatically()
            let token = try mcpSecrets.getOrCreate(.mcpAccess)
            guard let resources = Bundle.main.resourceURL else { throw IndexaError("mcp_resources_missing") }
            let notes = NotesMCP(python: Configuration.directory.appendingPathComponent("runtime/venv/bin/python"),
                script: resources.appendingPathComponent("hermes-plugin/mcp_notes.py"),
                profileHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/profiles/indexa"))
            guard let db else { throw IndexaError("mcp_database_unavailable") }
            let organizer = OrganizerStore(database: db)
            organizerStore = organizer
            let manager = try MCPManager(token: token, modules: [notes, FilesMCP(), OrganizerMCP(kind: .reminders, store: organizer), OrganizerMCP(kind: .calendar, store: organizer)],
                preferencesURL: Configuration.directory.appendingPathComponent("mcp-permissions.json"))
            // User requested report attachments; this grant only creates Indexa-owned exports.
            if try await db.value("files-mcp-initialized") == nil {
                try await manager.setPermissions(["create"],for:"files")
                try await manager.setEnabled(true,for:"files")
                try await db.setValue("files-mcp-initialized","1")
            }
            let server = try await Application.make(.init(name: "production", arguments: ["Indexa MCP"]))
            await manager.install(on: server)
            do { try await server.http.server.shared.start(address: .hostname("127.0.0.1", port: 43121)) }
            catch { await manager.stop(); try? await server.asyncShutdown(); throw error }
            mcpManager = manager; mcpServer = server
            mcpStatus = "Działa lokalnie · 127.0.0.1:43121"
            await refreshMCP()
            await connectMCPToHermes()
        } catch { mcpStatus = "Nie uruchomiono MCP: \(Self.message(error))" }
    }

    func stopMCP() async {
        if let task = mcpConnectionTask { _ = try? await task.value }
        await mcpManager?.stop()
        if let server = mcpServer { await server.http.server.shared.shutdown(); try? await server.asyncShutdown() }
        mcpServer = nil; mcpManager = nil; mcpStatus = "Zatrzymany"
        mcpHermesConnected = false
        mcpHermesStatus = "Oczekiwanie na MCP…"
    }

    func connectMCPToHermes() async {
        guard !mcpConnecting, let manager = mcpManager, let resources = Bundle.main.resourceURL else { return }
        mcpConnecting = true; mcpHermesConnected = false; mcpHermesStatus = "Łączenie automatyczne…"
        defer { mcpConnecting = false; mcpConnectionTask = nil }
        do {
            let token = try mcpSecrets.getOrCreate(.mcpAccess)
            let modules = await manager.snapshots().map(\.id)
            let task = Task { try await HermesMCPConnection.synchronize(token: token, modules: modules,
                script: resources.appendingPathComponent("connect-hermes-mcp.py")) }
            mcpConnectionTask = task
            _ = try await task.value
            mcpHermesConnected = true
            mcpHermesStatus = "Połączony automatycznie · profil indexa"
        } catch {
            mcpHermesStatus = "Nie udało się podłączyć Hermesa. Sprawdź jego instalację i wybierz Ponów połączenie."
        }
    }

    func refreshMCP() async {
        guard let manager = mcpManager else { return }
        mcpModules = await manager.snapshots()
        mcpActivity = await manager.auditEntries()
        organizerIssues = Dictionary(uniqueKeysWithValues: OrganizerKind.allCases.compactMap { kind in
            organizerStore?.accessIssue(kind).map { (kind.rawValue, $0) }
        })
    }

    func organizerScopeDescription(_ module: String) -> String {
        module == "files" ? "Tworzy raporty TXT, MD, CSV, JSON i PDF wyłącznie w katalogu eksportów Indexy. Bez odczytu innych plików na Macu. Wskazany raport może zostać dołączony do odpowiedzi w prywatnym Matrixie." : module == "calendar" ? "Odczyt obejmuje wszystkie istniejące kalendarze, również tylko do odczytu. Tworzenie wydarzeń ma osobne uprawnienie. Bez usuwania i wysyłania zaproszeń." : "Dostęp do istniejących list i przypomnień. Odczyt, tworzenie i oznaczanie jako wykonane mają osobne uprawnienia. Bez usuwania."
    }

    func requestOrganizerAccess(_ module: String) async {
        guard !organizerRequesting, let kind = OrganizerKind(rawValue: module), let organizerStore else { return }
        organizerRequesting = true
        defer { organizerRequesting = false }
        do {
            if try await !organizerStore.requestAccess(kind) {
                mcpNotice = "Nie przyznano dostępu. Możesz go zmienić w Ustawieniach systemowych → Prywatność i ochrona → \(kind.title)."
            }
        } catch { mcpNotice = "Nie udało się uzyskać zgody macOS. Sprawdź ustawienia prywatności systemu." }
        await refreshMCP()
    }

    func setMCPEnabled(_ enabled: Bool, module: String) async {
        do { try await mcpManager?.setEnabled(enabled, for: module); await refreshMCP(); await connectMCPToHermes() }
        catch { mcpNotice = "Nie zapisano zmiany: \(Self.message(error))" }
    }

    func setMCPPermission(_ permission: String, enabled: Bool, module: String) async {
        guard let manager = mcpManager else { return }
        do { try await manager.setPermission(permission, enabled: enabled, for: module); await refreshMCP(); await connectMCPToHermes() }
        catch { mcpNotice = "Nie zapisano zmiany: \(Self.message(error))" }
    }

    func copyMCPConfiguration() {
        do {
            let token = try mcpSecrets.getOrCreate(.mcpAccess)
            let config = "mcp_servers:\n" + mcpModules.map { module in
                "  indexa-\(module.id):\n    url: \"http://127.0.0.1:43121/mcp/\(module.id)\"\n    headers:\n      Authorization: \"Bearer \(token)\""
            }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(config, forType: .string)
            let change = NSPasteboard.general.changeCount
            Task {
                try? await Task.sleep(for: .seconds(60))
                if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
            }
            mcpNotice = "Konfiguracja z tokenem skopiowana. Schowek wyczyści się za minutę, jeśli niczego innego nie skopiujesz."
        } catch { mcpNotice = "Nie skopiowano konfiguracji: \(Self.message(error))" }
    }

    func rotateMCPToken() async {
        guard !mcpConnecting, !mcpRotating, mcpManager != nil else { return }
        mcpRotating = true
        defer { mcpRotating = false }
        do {
            let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
            try mcpSecrets.write(.mcpAccess, value: token)
            try await mcpManager?.rotateToken(token)
            await connectMCPToHermes()
            mcpNotice = "Token zmieniony; poprzedni już nie działa. Hermes jest synchronizowany automatycznie. Jeśli używasz innych klientów MCP, zaktualizuj ich token."
        } catch { mcpNotice = "Nie zmieniono tokena: \(Self.message(error))" }
    }

}
