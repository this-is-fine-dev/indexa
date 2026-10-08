import Foundation
import Testing
import Vapor
@testable import IndexaCore

struct WorkerTests {
    @Test func serializesSourcesAndCompletionNeverResubmitsForDelivery() async throws {
        let db=try Database(url:nil),server=try await Application.make(.testing)
        server.logger.logLevel = .critical
        server.http.server.configuration.hostname="127.0.0.1";server.http.server.configuration.port=0
        server.get("v1","capabilities") { _ in Response(status:.ok,body:.init(string:"{\"features\":{\"run_submission\":true,\"run_status\":true,\"run_approval_response\":true},\"idempotency\":{\"supported\":true,\"durable\":true}}")) }
        server.post("v1","runs") { req in ["run_id":"run_"+(req.headers.first(name:"Idempotency-Key") ?? ""),"status":"started"] }
        server.get("v1","runs",":id") { req in ["run_id":req.parameters.get("id")!,"status":"completed","output":"Zapisano syntetyczny wynik"] }
        try await server.http.server.shared.start(address:.hostname("127.0.0.1",port:0))
        let port=try #require(server.http.server.shared.localAddress?.port)
        let hermes=HermesClient(baseURL:URL(string:"http://127.0.0.1:\(port)")!,key:"fixture")
        let worker=AgentWorker(database:db,hermes:hermes)
        _ = try await db.accept(source:"pebble",sourceID:"1",text:"zapisz",recorded:1,digest:"a")
        _ = try await db.ingestMatrix(id:"$1",text:"dopisz",recorded:1)
        try await worker.tick(destination:"123")
        let first=try await db.tasks()
        #expect(first.filter{$0.state == "running"}.count == 1)
        #expect(first.filter{$0.state == "queued"}.count == 1)
        #expect(Set(first.map(\.session)).count == 1)
        try await worker.tick(destination:"123")
        #expect(try await db.outbox().count == 1)
        try await worker.tick(destination:"123")
        try await worker.tick(destination:"123")
        #expect(try await db.tasks().allSatisfy{$0.state == "completed"})
        #expect(try await db.outbox().count == 2)
        await server.http.server.shared.shutdown()
        try await server.asyncShutdown()
    }
    @Test func approvalIsOwnerBoundAndSingleUse() async throws {
        let db=try Database(url:nil)
        try await db.addApproval(request:"request1",run:"run1",event:"event1",owner:"123",description:"synthetic")
        let a=try #require(try await db.approvals().first)
        await #expect(throws:(any Error).self) { try await db.claimApproval(a.id,owner:"999") }
        _ = try await db.claimApproval(a.id,owner:"123")
        await #expect(throws:(any Error).self) { try await db.claimApproval(a.id,owner:"123") }
    }
    @Test func transientMatrixFailureRetriesSameTransaction() async throws {
        let db=try Database(url:nil),server=try await Application.make(.testing)
        server.logger.logLevel = .critical
        server.post("send") { _ in Response(status:.serviceUnavailable,body:.init(string:"{\"sent\":false}")) }
        try await server.http.server.shared.start(address:.hostname("127.0.0.1",port:0))
        let port=try #require(server.http.server.shared.localAddress?.port)
        let worker=OutboxWorker(database:db,matrix:MatrixClient(key:"fixture",baseURL:URL(string:"http://127.0.0.1:\(port)")!))
        try await db.enqueue(destination:"room",body:"synthetic")
        let id=try #require(try await db.nextDelivery()?.id)
        try await worker.tick()
        let retry=try #require(try await db.nextDelivery())
        #expect(retry.id == id)
        #expect(retry.state == "retry_wait")
        #expect(retry.nextAttempt > Date().timeIntervalSince1970)
        #expect(retry.attempts == 1)
        await server.http.server.shared.shutdown()
        try await server.asyncShutdown()
    }

}
