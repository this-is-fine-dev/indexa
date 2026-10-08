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
            let manager = try MCPManager(token: token, modules: [notes],
                preferencesURL: Configuration.directory.appendingPathComponent("mcp-permissions.json"))
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
        mcpHermesStatus = "Oczekiwanie na MCP…"
    }

    func connectMCPToHermes() async {
        guard !mcpConnecting, let manager = mcpManager, let resources = Bundle.main.resourceURL else { return }
        mcpConnecting = true; mcpHermesStatus = "Łączenie automatyczne…"
        defer { mcpConnecting = false; mcpConnectionTask = nil }
        do {
            let token = try mcpSecrets.getOrCreate(.mcpAccess)
            let modules = await manager.snapshots().map(\.id)
            let task = Task { try await HermesMCPConnection.synchronize(token: token, modules: modules,
                script: resources.appendingPathComponent("connect-hermes-mcp.py")) }
            mcpConnectionTask = task
            _ = try await task.value
            mcpHermesStatus = "Połączony automatycznie · profil indexa"
        } catch {
            mcpHermesStatus = "Nie udało się podłączyć Hermesa. Sprawdź jego instalację i wybierz Ponów połączenie."
        }
    }

    func refreshMCP() async {
        guard let manager = mcpManager else { return }
        mcpModules = await manager.snapshots()
        mcpActivity = await manager.auditEntries()
    }

    func setMCPEnabled(_ enabled: Bool, module: String) async {
        do { try await mcpManager?.setEnabled(enabled, for: module); await refreshMCP() }
        catch { mcpNotice = "Nie zapisano zmiany: \(Self.message(error))" }
    }

    func setMCPPermission(_ permission: String, enabled: Bool, module: String) async {
        guard let manager = mcpManager else { return }
        do { try await manager.setPermission(permission, enabled: enabled, for: module); await refreshMCP() }
        catch { mcpNotice = "Nie zapisano zmiany: \(Self.message(error))" }
    }

    func copyMCPConfiguration() {
        do {
            let token = try mcpSecrets.getOrCreate(.mcpAccess)
            let config = """
            mcp_servers:
              indexa-notes:
                url: "http://127.0.0.1:43121/mcp/notes"
                headers:
                  Authorization: "Bearer \(token)"
            """
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

    func testMCPConnection() async {
        do {
            guard let token = try mcpSecrets.read(.mcpAccess) else { throw IndexaError("mcp_token_missing") }
            let url = URL(string: "http://127.0.0.1:43121/mcp/notes")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"; request.timeoutInterval = 5
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Indexa connection test","version":"1"}}}"#.utf8)
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let sid = response.value(forHTTPHeaderField: "Mcp-Session-Id"),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["result"] != nil else { throw IndexaError("mcp_handshake_failed") }
            request.httpMethod = "DELETE"; request.httpBody = nil
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try await session.data(for: request)
            mcpNotice = "Połączenie MCP i uwierzytelnienie działają. Ten test nie odczytuje ani nie zmienia notatek."
        } catch { mcpNotice = "Test nie powiódł się: \(Self.message(error))" }
    }
}
