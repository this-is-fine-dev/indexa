import Foundation
import Vapor

public enum MCPValue: Codable, Sendable, Equatable {
    case object([String: MCPValue]), array([MCPValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String:MCPValue].self) { self = .object(v) }
        else { self = .array(try c.decode([MCPValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> MCPValue? { if case .object(let v) = self { return v[key] }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
}

public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: MCPValue
    public let requiredPermissions: Set<String>
    public init(name: String, description: String, inputSchema: MCPValue, requiredPermissions: Set<String> = []) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.requiredPermissions = requiredPermissions
    }
    var wire: MCPValue { .object(["name":.string(name), "description":.string(description), "inputSchema":inputSchema]) }
}
public struct MCPToolResult: Sendable {
    public let content: [MCPValue]
    public let isError: Bool
    public init(content: [MCPValue], isError: Bool = false) { self.content = content; self.isError = isError }
    public static func text(_ text: String, isError: Bool = false) -> Self { .init(content:[.object(["type":.string("text"),"text":.string(text)])],isError:isError) }
    var wire: MCPValue { .object(["content":.array(content),"isError":.bool(isError)]) }
}
public protocol MCPModule: Sendable {
    var id: String { get }
    var title: String { get }
    var permissionKeys: Set<String> { get }
    func tools() async throws -> [MCPTool]
    func call(tool: String, arguments: MCPValue) async throws -> MCPToolResult
}
public struct MCPModuleState: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let enabled: Bool
    public let permissions: Set<String>
    public let availablePermissions: Set<String>
}
public struct MCPAuditEntry: Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let module: String
    public let tool: String
    public let result: String
    public let duration: TimeInterval
    public let session: UUID
}

/// One loopback listener, independent MCP sessions and permission gates per module.
public actor MCPManager {
    private struct Preference: Codable { var enabled = false; var permissions: Set<String> = [] }
    private struct Session {
        let module: String
        let version: String
        var ready = false
        var touched = Date()
        var events: AsyncStream<String>.Continuation?
        var streamID: UUID?
    }
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private var token: String
    private let modules: [String:any MCPModule]
    private let preferencesURL: URL?
    private var preferences: [String:Preference]
    private var sessions: [UUID:Session] = [:]
    private var audit: [MCPAuditEntry] = []
    private var maintenance: Task<Void,Never>?
    private var activeCalls = 0
    private var drainWaiters: [CheckedContinuation<Void,Never>] = []
    private var running = true
    private var port = 43121

    public init(token: String, modules: [any MCPModule] = [], preferencesURL: URL? = nil) throws {
        guard token.utf8.count >= 32, token.utf8.count <= 256,
              token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw IndexaError("invalid_mcp_token") }
        var registry = [String:any MCPModule]()
        for module in modules {
            guard !module.id.isEmpty, module.id.utf8.count <= 64,
                  module.id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  registry[module.id] == nil else { throw IndexaError("invalid_mcp_module") }
            registry[module.id] = module
        }
        self.token = token; self.modules = registry; self.preferencesURL = preferencesURL
        if let url = preferencesURL, FileManager.default.fileExists(atPath:url.path) {
            let data = try Data(contentsOf:url)
            guard data.count <= 262144 else { throw IndexaError("invalid_mcp_preferences") }
            self.preferences = try JSONDecoder().decode([String:Preference].self,from:data)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        } else { self.preferences = [:] }
    }
    public func snapshots() -> [MCPModuleState] {
        modules.values.map { module in
            let p = preferences[module.id] ?? Preference()
            return MCPModuleState(id:module.id,title:module.title,enabled:p.enabled,permissions:p.permissions.intersection(module.permissionKeys),availablePermissions:module.permissionKeys)
        }.sorted { $0.id < $1.id }
    }
    var isDraining: Bool { !running && activeCalls > 0 }
    var activeStreamCount: Int { sessions.values.filter { $0.events != nil }.count }
    public func auditEntries() -> [MCPAuditEntry] { audit.reversed() }
    public func setEnabled(_ enabled: Bool, for module: String) throws {
        guard modules[module] != nil else { throw IndexaError("unknown_mcp_module") }
        var p = preferences[module] ?? Preference(); p.enabled = enabled
        try save(p,for:module); notify(module)
    }
    public func setPermissions(_ permissions: Set<String>, for module: String) throws {
        guard let m = modules[module], permissions.isSubset(of:m.permissionKeys) else { throw IndexaError("invalid_mcp_permission") }
        var p = preferences[module] ?? Preference(); p.permissions = permissions
        try save(p,for:module); notify(module)
    }
    public func setPermission(_ permission: String, enabled: Bool, for module: String) throws {
        var permissions = preferences[module]?.permissions ?? []
        if enabled { permissions.insert(permission) } else { permissions.remove(permission) }
        try setPermissions(permissions, for: module)
    }
    private func save(_ preference: Preference, for module: String) throws {
        var updated = preferences; updated[module] = preference
        if let url = preferencesURL {
            let data = try JSONEncoder().encode(updated)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".mcp-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw IndexaError("mcp_preferences_write_failed") }
            defer { try? FileManager.default.removeItem(at:temporary) }
            let handle = try FileHandle(forWritingTo:temporary)
            do { try handle.write(contentsOf:data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard rename(temporary.path,url.path) == 0 else { throw IndexaError("mcp_preferences_write_failed") }
        }
        preferences = updated
    }
    public func rotateToken(_ token: String) throws {
        guard token.utf8.count >= 32, token.utf8.count <= 256, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw IndexaError("invalid_mcp_token") }
        self.token = token
        for session in sessions.values { session.events?.finish() }
        sessions.removeAll()
    }
    public func stop() async {
        running = false; maintenance?.cancel(); maintenance = nil
        for session in sessions.values { session.events?.finish() }
        sessions.removeAll()
        if activeCalls > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
    }
    public func install(on app: Application, port: Int = 43121) {
        self.port = port
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = port
        app.routes.defaultMaxBodySize = "256kb"
        app.logger.logLevel = .critical
        for method: HTTPMethod in [.POST,.GET,.DELETE] {
            app.on(method,"mcp",":module",body:.collect(maxSize:"256kb")) { request async throws -> Response in
                try await self.handle(request)
            }
        }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(15)) } catch { return }
                await self?.maintain()
            }
        }
    }
    private func maintain() {
        let expired = sessions.filter { Date().timeIntervalSince($0.value.touched) > 1800 }.map(\.key)
        for id in expired { sessions.removeValue(forKey:id)?.events?.finish() }
        // Heartbeats detect disconnected readers without retaining unbounded streams.
        for session in sessions.values { session.events?.yield(": keepalive\n\n") }
    }
    private func notify(_ module: String) {
        for session in sessions.values where session.module == module && session.ready {
            session.events?.yield("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n")
        }
    }
    private func authenticate(_ request: Request) throws {
        guard running else { throw Abort(.serviceUnavailable) }
        let expectedHost = "127.0.0.1:\(port)"
        let hosts = request.headers["Host"]
        guard hosts.count == 1, hosts[0] == expectedHost else { throw Abort(.forbidden) }
        let origins = request.headers["Origin"]
        guard origins.isEmpty || (origins.count == 1 && origins[0] == "http://\(expectedHost)") else { throw Abort(.forbidden) }
        let auth = request.headers["Authorization"]
        guard auth.count == 1 else { throw Abort(.unauthorized) }
        let actual = Array(auth[0].utf8), expected = Array("Bearer \(token)".utf8)
        var difference = actual.count ^ expected.count
        for i in 0..<max(actual.count,expected.count) { difference |= Int((i < actual.count ? actual[i] : 0) ^ (i < expected.count ? expected[i] : 0)) }
        guard difference == 0 else { throw Abort(.unauthorized) }
        for name in ["MCP-Session-Id","MCP-Protocol-Version"] {
            guard request.headers[name].count <= 1 else { throw Abort(.badRequest) }
        }
        if let version = request.headers.first(name:"MCP-Protocol-Version"), !Self.protocolVersions.contains(version) { throw Abort(.badRequest) }
    }
    private func sessionID(_ request: Request, module: String) throws -> UUID {
        guard let value = request.headers.first(name:"MCP-Session-Id"), let id = UUID(uuidString:value) else { throw Abort(.badRequest) }
        guard let s = sessions[id], s.module == module, Date().timeIntervalSince(s.touched) <= 1800 else { throw Abort(.notFound) }
        if let version = request.headers.first(name:"MCP-Protocol-Version"), version != s.version { throw Abort(.badRequest) }
        sessions[id]?.touched = Date()
        return id
    }
    private func handle(_ request: Request) async throws -> Response {
        try authenticate(request)
        guard let moduleID = request.parameters.get("module"), let module = modules[moduleID] else { throw Abort(.notFound) }
        if request.method == .DELETE {
            let id = try sessionID(request,module:moduleID)
            sessions.removeValue(forKey:id)?.events?.finish()
            return Response(status:.ok)
        }
        if request.method == .GET {
            guard accepts(request,"text/event-stream") else { throw Abort(.notAcceptable) }
            let id = try sessionID(request,module:moduleID)
            guard sessions[id]?.ready == true else { throw Abort(.badRequest) }
            sessions[id]?.events?.finish()
            let pair = AsyncStream<String>.makeStream(bufferingPolicy:.bufferingNewest(4))
            let streamID = UUID()
            sessions[id]?.events = pair.continuation; sessions[id]?.streamID = streamID
            pair.continuation.yield(": connected\n\n")
            return Response(status:.ok,headers:["Content-Type":"text/event-stream","Cache-Control":"no-cache"],body:.init(managedAsyncStream:{ writer in
                do {
                    for await event in pair.stream { try await writer.write(.buffer(ByteBuffer(string:event))) }
                } catch {
                    pair.continuation.finish()
                    await self.clearStream(id,streamID:streamID)
                    throw error
                }
                await self.clearStream(id,streamID:streamID)
            }))
        }
        guard accepts(request,"application/json"), accepts(request,"text/event-stream") else { throw Abort(.notAcceptable) }
        guard request.headers.contentType?.type == "application", request.headers.contentType?.subType == "json" else { throw Abort(.unsupportedMediaType) }
        guard let body = request.body.data, body.readableBytes <= 262144 else { throw Abort(.payloadTooLarge) }
        let rpc: MCPValue
        do { rpc = try JSONDecoder().decode(MCPValue.self,from:Data(body.readableBytesView)) }
        catch { return try self.error(.null,code:-32700,message:"Parse error") }
        guard case .object(let object) = rpc, rpc["jsonrpc"] == .string("2.0"), let method = rpc["method"]?.stringValue,
              !method.isEmpty else { return try error(.null,code:-32600,message:"Invalid request") }
        let id = object["id"]
        if let id { switch id { case .string,.number: break; default: return try error(.null,code:-32600,message:"Invalid request id") } }
        if let params = rpc["params"], case .object = params {} else if rpc["params"] != nil { return try error(id ?? .null,code:-32602,message:"Invalid params") }
        if method == "initialize" {
            guard let id, request.headers["MCP-Session-Id"].isEmpty,
                  let requested = rpc["params"]?["protocolVersion"]?.stringValue,
                  case .object = rpc["params"]?["capabilities"],
                  rpc["params"]?["clientInfo"]?["name"]?.stringValue != nil,
                  rpc["params"]?["clientInfo"]?["version"]?.stringValue != nil else { return try error(id ?? .null,code:-32602,message:"Invalid initialization") }
            maintain()
            guard sessions.count < 64 else { throw Abort(.tooManyRequests) }
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            let session = UUID(); sessions[session] = Session(module:moduleID,version:version)
            let response = try result(id,.object(["protocolVersion":.string(version),"capabilities":.object(["tools":.object(["listChanged":.bool(true)])]),"serverInfo":.object(["name":.string("indexa-\(moduleID)"),"version":.string("1.0.0")])]))
            response.headers.add(name:"MCP-Session-Id",value:session.uuidString)
            return response
        }
        let session = try sessionID(request,module:moduleID)
        if id == nil {
            if method == "notifications/initialized" { sessions[session]?.ready = true }
            return Response(status:.accepted)
        }
        let requestID = id!
        if method == "ping" { return try result(requestID,.object([:])) }
        guard sessions[session]?.ready == true else { return try error(requestID,code:-32600,message:"Session not initialized") }
        guard method == "tools/list" || method == "tools/call" else { return try error(requestID,code:-32601,message:"Method not found") }
        let tools: [MCPTool]
        do { tools = try await module.tools() }
        catch { return try self.error(requestID,code:-32603,message:"Module unavailable") }
        // Recheck after module discovery: actor suspension must not bypass a revoke or token rotation.
        try authenticate(request)
        guard sessions[session] != nil else { throw Abort(.notFound) }
        let preference = preferences[moduleID] ?? Preference()
        let granted = preference.permissions.intersection(module.permissionKeys)
        if method == "tools/list" {
            let visible = preference.enabled ? tools.filter { $0.requiredPermissions.isSubset(of:granted) } : []
            return try result(requestID,.object(["tools":.array(visible.map(\.wire))]))
        }
        guard let name = rpc["params"]?["name"]?.stringValue,
              let tool = tools.first(where:{ $0.name == name }) else { return try error(requestID,code:-32602,message:"Unknown tool") }
        let start = Date()
        guard preference.enabled, tool.requiredPermissions.isSubset(of:granted) else {
            record(moduleID,tool:name,result:"denied",start:start,session:session)
            return try result(requestID,MCPToolResult.text("Tool disabled or permission denied",isError:true).wire)
        }
        let arguments = rpc["params"]?["arguments"] ?? .object([:])
        guard case .object = arguments else { return try error(requestID,code:-32602,message:"Invalid arguments") }
        guard activeCalls < 16 else { throw Abort(.tooManyRequests) }
        activeCalls += 1
        defer {
            activeCalls -= 1
            if activeCalls == 0 { let waiters = drainWaiters; drainWaiters.removeAll(); waiters.forEach { $0.resume() } }
        }
        do {
            let value = try await module.call(tool:name,arguments:arguments)
            record(moduleID,tool:name,result:value.isError ? "error":"ok",start:start,session:session)
            return try result(requestID,value.wire)
        } catch {
            record(moduleID,tool:name,result:"error",start:start,session:session)
            return try result(requestID,MCPToolResult.text("Tool execution failed",isError:true).wire)
        }
    }
    private func accepts(_ request: Request, _ type: String) -> Bool {
        request.headers["Accept"].joined(separator:",").split(separator:",").contains { $0.split(separator:";",omittingEmptySubsequences:false).first?.trimmingCharacters(in:.whitespaces) == type }
    }
    private func clearStream(_ session: UUID, streamID: UUID) {
        if sessions[session]?.streamID == streamID { sessions[session]?.events = nil; sessions[session]?.streamID = nil }
    }
    private func record(_ module: String, tool: String, result: String, start: Date, session: UUID) {
        audit.append(.init(id:UUID(),date:Date(),module:module,tool:tool,result:result,duration:Date().timeIntervalSince(start),session:session))
        if audit.count > 512 { audit.removeFirst(audit.count-512) }
    }
    private func result(_ id: MCPValue, _ value: MCPValue) throws -> Response { try json(.object(["jsonrpc":.string("2.0"),"id":id,"result":value])) }
    private func error(_ id: MCPValue, code: Int, message: String) throws -> Response { try json(.object(["jsonrpc":.string("2.0"),"id":id,"error":.object(["code":.number(Double(code)),"message":.string(message)])])) }
    private func json(_ value: MCPValue) throws -> Response { Response(status:.ok,headers:["Content-Type":"application/json"],body:.init(data:try JSONEncoder().encode(value))) }
}
