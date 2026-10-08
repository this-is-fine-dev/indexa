import Foundation
import Testing
import Vapor
@testable import IndexaCore

struct WorkerTests {
    @Test func serializesSourcesAndCompletionNeverResubmitsForDelivery() async throws {
        let db=try Database(url:nil),server=try await Application.make(.testing)
        server.logger.logLevel = .critical
        server.http.server.configuration.hostname="127.0.0.1";server.http.server.configuration.port=0
        server.get("api","sessions") { _ in Response(status:.ok,body:.init(string:"{\"data\":[{\"id\":\"shared-bot-chat\",\"title\":\"Bot Chat\",\"archived\":false}]}")) }
        server.get("api","sessions","shared-bot-chat","messages") { _ in Response(status:.ok,body:.init(string:"{\"data\":[]}")) }
        server.get("v1","capabilities") { _ in Response(status:.ok,body:.init(string:"{\"features\":{\"run_submission\":true,\"run_status\":true,\"run_approval_response\":true},\"idempotency\":{\"supported\":true,\"durable\":true}}")) }
        server.post("v1","runs") { req in ["run_id":"run_"+(req.headers.first(name:"Idempotency-Key") ?? ""),"status":"started"] }
        server.get("v1","runs",":id") { _ in Response(status:.ok,body:.init(string:"{\"status\":\"completed\",\"output\":\"Zapisano syntetyczny wynik\",\"created_at\":1,\"updated_at\":10}")) }
        try await server.http.server.shared.start(address:.hostname("127.0.0.1",port:0))
        let port=try #require(server.http.server.shared.localAddress?.port)
        let hermes=HermesClient(baseURL:URL(string:"http://127.0.0.1:\(port)")!,key:"fixture")
        let worker=AgentWorker(database:db,hermes:hermes)
        _ = try await db.accept(source:"pebble",sourceID:"1",text:"zapisz",recorded:1,digest:"a")
        _ = try await db.ingestMatrix(id:"$1",text:"dopisz",recorded:1)
        try await worker.tick(destination:"123")
        #expect(try await db.nextDelivery()?.body == "🎙️ Z pierścienia\nzapisz")
        let first=try await db.tasks()
        #expect(first.filter{$0.state == "running"}.count == 1)
        #expect(first.filter{$0.state == "queued"}.count == 1)
        #expect(Set(first.map(\.session)) == ["shared-bot-chat"])
        try await worker.tick(destination:"123")
        #expect(try await db.outbox().count == 2)
        try await worker.tick(destination:"123")
        try await worker.tick(destination:"123")
        #expect(try await db.tasks().allSatisfy{$0.state == "completed"})
        #expect(try await db.outbox().count == 3)
        #expect(try await db.tasks().allSatisfy{$0.output == "Zapisano syntetyczny wynik" && $0.deliveryState == "pending"})
        let timings=try await db.latencyReport()
        for stage in ["preparation","submission","hermes","answer_lookup"] { #expect(timings.contains("stage=\(stage) ")) }
        #expect(!timings.contains("Zapisano syntetyczny wynik"))
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
        let timings=try await db.latencyReport()
        #expect(timings.contains("stage=delivery ") && timings.contains("status=503"))
        await server.http.server.shared.shutdown()
        try await server.asyncShutdown()
    }

    @Test func completedRunUsesExistingMirrorDeliveryIdentity() async throws {
        let db=try Database(url:nil),server=try await Application.make(.testing)
        server.logger.logLevel = .critical
        server.get("v1","runs","run") { _ in Response(status:.ok,body:.init(string:"{\"status\":\"completed\",\"output\":\"answer\",\"created_at\":1,\"updated_at\":10}")) }
        server.get("api","sessions",":session","messages") { _ in Response(status:.ok,body:.init(string:"{\"data\":[{\"role\":\"assistant\",\"content\":\"answer\",\"timestamp\":4,\"finish_reason\":\"stop\"}]}")) }
        try await server.http.server.shared.start(address:.hostname("127.0.0.1",port:0))
        let port=try #require(server.http.server.shared.localAddress?.port)
        let hermes=HermesClient(baseURL:URL(string:"http://127.0.0.1:\(port)")!,key:"fixture")
        let task=try await db.accept(source:"matrix",sourceID:"new",text:"request",recorded:1,digest:"digest")
        try await db.setRun(task.id,run:"run")
        let identity=try #require(try await hermes.finalAnswerID(session:"shared",output:"answer",createdAt:1,completedAt:10))
        try await db.enqueue(event:identity,kind:"shared-answer",destination:"room",body:"answer")
        let worker=AgentWorker(database:db,hermes:hermes)
        try await worker.tick(destination:"room")
        #expect(try await db.outbox().count == 1)
        #expect(try await db.tasks().first?.state == "completed")
        #expect(try await db.tasks().first?.deliveryState == "pending")
        await server.http.server.shared.shutdown()
        try await server.asyncShutdown()
    }

}
