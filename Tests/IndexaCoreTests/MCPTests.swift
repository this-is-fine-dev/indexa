import Foundation
import Testing
import VaporTesting
@testable import IndexaCore

private actor TestMCPModule: MCPModule {
    nonisolated let id: String
    nonisolated let title = "Test"
    nonisolated let permissionKeys: Set<String> = ["read","write"]
    private(set) var calls = 0
    private let hold: Bool
    private var release: CheckedContinuation<Void,Never>?
    init(_ id: String = "test", hold: Bool = false) { self.id = id; self.hold = hold }
    func tools() async throws -> [MCPTool] {
        [.init(name:"test_read",description:"Read",inputSchema:.object(["type":.string("object")]),requiredPermissions:["read"])]
    }
    func call(tool: String, arguments: MCPValue) async throws -> MCPToolResult {
        calls += 1
        if hold { await withCheckedContinuation { release = $0 } }
        return .text("ok")
    }
    func resume() { release?.resume(); release = nil }
}

struct MCPTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MCP_TEST_PYTHON"] != nil))
    func actualHermesSDK() async throws {
        let python = ProcessInfo.processInfo.environment["MCP_TEST_PYTHON"]!
        let app = try await Application.make(.testing)
        let manager = try MCPManager(token: token, modules: [TestMCPModule()])
        await manager.install(on: app, port: 43129)
        try await manager.setEnabled(true, for: "test")
        try await manager.setPermissions(["read"], for: "test")
        try await app.http.server.shared.start(address: .hostname("127.0.0.1", port: 43129))
        do {
            let input = try JSONSerialization.data(withJSONObject: ["url": "http://127.0.0.1:43129/mcp/test", "token": token])
            let status = try await Task.detached {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = ["Tests/test_mcp_client.py"]
                process.standardInput = pipe
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
                defer { timeout.cancel() }
                try pipe.fileHandleForWriting.write(contentsOf: input)
                try pipe.fileHandleForWriting.close()
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            #expect(status == 0)
        } catch {
            await manager.stop(); await app.http.server.shared.shutdown(); try await app.asyncShutdown()
            throw error
        }
        await manager.stop(); await app.http.server.shared.shutdown(); try await app.asyncShutdown()
    }
    private let token = String(repeating:"a",count:48)
    private func headers(session: String? = nil, token: String? = nil) -> HTTPHeaders {
        var headers: HTTPHeaders = ["Host":"127.0.0.1:43121","Authorization":"Bearer \(token ?? self.token)","Content-Type":"application/json","Accept":"application/json, text/event-stream","MCP-Protocol-Version":"2025-11-25"]
        if let session { headers.add(name:"MCP-Session-Id",value:session) }; return headers
    }
    private func body(_ method: String, params: MCPValue = .object([:]), notification: Bool = false) throws -> ByteBuffer {
        var object: [String:MCPValue] = ["jsonrpc":.string("2.0"),"method":.string(method),"params":params]
        if !notification { object["id"] = .number(1) }
        return ByteBuffer(data:try JSONEncoder().encode(MCPValue.object(object)))
    }
    private func initialize(_ app: Application, module: String = "test") async throws -> String {
        let data = try body("initialize",params:.object(["protocolVersion":.string("2025-11-25"),"capabilities":.object([:]),"clientInfo":.object(["name":.string("test"),"version":.string("1")])]))
        var session = ""
        try await app.test(.POST,"/mcp/\(module)",headers:headers(),body:data) {
            #expect($0.status == .ok)
            session = try #require($0.headers.first(name:"MCP-Session-Id"))
        }
        try await app.test(.POST,"/mcp/\(module)",headers:headers(session:session),body:body("notifications/initialized",notification:true)) { #expect($0.status == .accepted) }
        return session
    }
    @Test func permissionChecksApplyToCachedCallsAndPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("preferences.json")
        let module = TestMCPModule(), app = try await Application.make(.testing)
        let manager = try MCPManager(token:token,modules:[module],preferencesURL:url)
        await manager.install(on:app)
        let session = try await initialize(app)
        let call = try body("tools/call",params:.object(["name":.string("test_read"),"arguments":.object(["private":.string("not in audit")])]))
        try await app.test(.POST,"/mcp/test",headers:headers(session:session),body:body("tools/list")) {
            let value = try JSONDecoder().decode(MCPValue.self,from:Data($0.body.readableBytesView))
            #expect(value["result"]?["tools"] == .array([]))
        }
        try await manager.setEnabled(true,for:"test")
        try await manager.setPermissions(["read"],for:"test")
        try await app.test(.POST,"/mcp/test",headers:headers(session:session),body:call) {
            let value = try JSONDecoder().decode(MCPValue.self,from:Data($0.body.readableBytesView))
            #expect(value["result"]?["isError"] == .bool(false))
        }
        #expect(await module.calls == 1)
        try await manager.setPermissions([],for:"test")
        try await app.test(.POST,"/mcp/test",headers:headers(session:session),body:call) {
            let value = try JSONDecoder().decode(MCPValue.self,from:Data($0.body.readableBytesView))
            #expect(value["result"]?["isError"] == .bool(true))
        }
        try await manager.setPermissions(["read"],for:"test")
        try await manager.setEnabled(false,for:"test")
        try await app.test(.POST,"/mcp/test",headers:headers(session:session),body:call) { #expect($0.status == .ok) }
        #expect(await module.calls == 1)
        #expect(await manager.auditEntries().map(\.result) == ["denied","denied","ok"])
        let restored = try MCPManager(token:token,modules:[module],preferencesURL:url)
        #expect(await restored.snapshots().first?.enabled == false)
        #expect((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? Int) == 0o600)
        await manager.stop(); await restored.stop(); try await app.asyncShutdown()
    }
    @Test func transportRejectsRebindingDuplicateAuthAndCrossModuleSessions() async throws {
        let app = try await Application.make(.testing)
        let manager = try MCPManager(token:token,modules:[TestMCPModule(),TestMCPModule("other")])
        await manager.install(on:app)
        let session = try await initialize(app)
        let ping = try body("ping")
        var bad = headers(session:session); bad.add(name:"Origin",value:"https://evil.example")
        try await app.test(.POST,"/mcp/test",headers:bad,body:ping) { #expect($0.status == .forbidden) }
        bad = headers(session:session); bad.replaceOrAdd(name:"Host",value:"evil.example:43121")
        try await app.test(.POST,"/mcp/test",headers:bad,body:ping) { #expect($0.status == .forbidden) }
        bad = headers(session:session); bad.add(name:"Authorization",value:"Bearer \(token)")
        try await app.test(.POST,"/mcp/test",headers:bad,body:ping) { #expect($0.status == .unauthorized) }
        try await app.test(.POST,"/mcp/other",headers:headers(session:session),body:ping) { #expect($0.status == .notFound) }
        bad = headers(session:session); bad.replaceOrAdd(name:"MCP-Protocol-Version",value:"invalid")
        try await app.test(.POST,"/mcp/test",headers:bad,body:ping) { #expect($0.status == .badRequest) }
        try await manager.rotateToken(String(repeating:"b",count:48))
        try await app.test(.POST,"/mcp/test",headers:headers(session:session),body:ping) { #expect($0.status == .unauthorized) }
        try await app.test(.POST,"/mcp/test",headers:headers(session:session,token:String(repeating:"b",count:48)),body:ping) { #expect($0.status == .notFound) }
        await manager.stop(); try await app.asyncShutdown()
    }
    @Test func sseSignalsToolChangesAndRotationClosesStream() async throws {
        let app = try await Application.make(.testing), manager = try MCPManager(token:token,modules:[TestMCPModule()])
        await manager.install(on:app)
        let session = try await initialize(app)
        let reader = Task {
            try await app.test(.GET,"/mcp/test",headers:headers(session:session)) {
                #expect($0.status == .ok)
                #expect($0.body.string.contains("notifications/tools/list_changed"))
            }
        }
        for _ in 0..<100 {
            if await manager.activeStreamCount == 1 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        #expect(await manager.activeStreamCount == 1)
        try await manager.setEnabled(true,for:"test")
        try await manager.rotateToken(String(repeating:"b",count:48))
        _ = try await reader.value
        #expect(await manager.activeStreamCount == 0)
        await manager.stop(); try await app.asyncShutdown()
    }
    @Test func stopDrainsDispatchedCallsAndRejectsNewCalls() async throws {
        let app = try await Application.make(.testing), module = TestMCPModule(hold:true)
        let manager = try MCPManager(token:token,modules:[module])
        await manager.install(on:app)
        try await manager.setEnabled(true,for:"test")
        try await manager.setPermissions(["read"],for:"test")
        let session = try await initialize(app)
        let call = try body("tools/call",params:.object(["name":.string("test_read")]))
        let request = Task {
            try await app.test(.POST,"/mcp/test",headers:headers(session:session),body:call) { #expect($0.status == .ok) }
        }
        for _ in 0..<100 {
            if await module.calls == 1 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        #expect(await module.calls == 1)
        let stopping = Task { await manager.stop() }
        for _ in 0..<100 {
            if await manager.isDraining { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        #expect(await manager.isDraining)
        try await app.test(.POST,"/mcp/test",headers:headers(session:session),body:call) { #expect($0.status == .serviceUnavailable) }
        await module.resume()
        _ = try await request.value
        await stopping.value
        #expect(await manager.isDraining == false)
        try await app.asyncShutdown()
    }

}
