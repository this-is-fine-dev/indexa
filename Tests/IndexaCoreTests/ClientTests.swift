import Foundation
import Testing
import Vapor
@testable import IndexaCore

struct ClientTests {
    @Test func hermesRunContractAndMatrixFailureSemantics() async throws {
        let server = try await Application.make(.testing)
        server.http.server.configuration.hostname = "127.0.0.1"
        server.http.server.configuration.port = 0
        server.logger.logLevel = .critical
        server.post("v1","runs") { req -> Response in
            guard req.headers.first(name:"Idempotency-Key") == "event-id", req.headers.bearerAuthorization?.token == "fixture-key",
                  let data = req.body.data, let object = try JSONSerialization.jsonObject(with:Data(data.readableBytesView)) as? [String:Any], object["session_id"] as? String == "scope-1" else { throw Abort(.badRequest) }
            return Response(status:.accepted,headers:["Content-Type":"application/json"],body:.init(string:"{\"run_id\":\"run_1\",\"status\":\"started\"}"))
        }
        server.get("v1","runs","run_1") { _ in ["status":"interrupted","run_id":"run_1","session_id":"scope-1"] }
        server.post("send") { _ in Response(status:.tooManyRequests,headers:["Content-Type":"application/json"],body:.init(string:"{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":7}}")) }
        try await server.http.server.shared.start(address:.hostname("127.0.0.1",port:0))
        let port = try #require(server.http.server.shared.localAddress?.port)
        let base = URL(string:"http://127.0.0.1:\(port)")!
        let hermes = HermesClient(baseURL:base,key:"fixture-key")
        let payload = try hermes.payload(input:"synthetic",session:"scope-1")
        #expect(try await hermes.submit(payload:payload,key:"event-id") == "run_1")
        #expect(try await hermes.submit(payload:payload,key:"event-id") == "run_1")
        #expect(try await hermes.status("run_1").state == "interrupted")
        let matrix = MatrixClient(key:"fixture-token",baseURL:base)
        do { _ = try await matrix.send(id:"txn-1",room:"1",text:"żółć"); Issue.record("Expected 429") }
        catch let error as APIError { #expect(error.retryAfter == 7); #expect(error.code == 429) }
        await server.http.server.shared.shutdown()
        try await server.asyncShutdown()
    }
    @Test func chunksAndOwnerAuthorization() {
        let text = String(repeating:"🧑🏽‍💻Żółć\n",count:900)
        let parts = MessageParts.split(text)
        #expect(parts.joined() == text)
        #expect(parts.allSatisfy { $0.utf16.count <= 3900 })
        #expect(MatrixIdentity.allowed(room:"1",user:"2",ownerRoom:"1",ownerUser:"2"))
        #expect(!MatrixIdentity.allowed(room:"1",user:"3",ownerRoom:"1",ownerUser:"2"))
        #expect(!MatrixIdentity.allowed(room:"other",user:"2",ownerRoom:"1",ownerUser:"2"))
    }
}
