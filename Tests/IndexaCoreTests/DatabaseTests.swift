import Foundation
import Testing
@testable import IndexaCore

struct DatabaseTests {
    @Test func durableDedupeRecoveryAndAtomicOutbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")
        let db = try Database(url: url)
        let a = try await db.accept(source: "pebble", sourceID: "one", text: "Żółta notatka", recorded: 1000, digest: "a")
        let again = try await db.accept(source: "pebble", sourceID: "one", text: "Żółta notatka", recorded: 1000, digest: "a")
        #expect(a.id == again.id)
        #expect(again.duplicate)
        _ = try await db.accept(source: "pebble", sourceID: "two", text: "Żółta notatka", recorded: 2000, digest: "a")
        #expect(try await db.tasks().count == 2)
        let task = try #require(try await db.nextTask())
        try await db.markSubmitting(task.id, payload: Data("{}".utf8))
        let restarted = try Database(url: url)
        try await restarted.recover()
        #expect(try await restarted.tasks().first(where: {$0.id == task.id})?.state == "needs_review")
        #expect(try await restarted.nextTask() == nil)
        try await restarted.finish(task.id, state: "completed", result: "Zapisano", destination: "123")
        #expect(try await restarted.outbox().count == 1)
        try await restarted.finish(task.id, state: "completed", result: "Zapisano", destination: "123")
        #expect(try await restarted.outbox().count == 1)
        #expect(try await restarted.nextTask()?.id != task.id)
    }
    @Test func testEventsAndMatrixCursorAreDurableWithoutExecution() async throws {
        let db = try Database(url: nil)
        _ = try await db.accept(source: "pebble", sourceID: "test", text: "test", recorded: 1, digest: "a", isTest: true)
        #expect(try await db.tasks().isEmpty)
        _ = try await db.ingestMatrix(id: "$42", text: "dopisz", recorded: 1)
        _ = try await db.ingestMatrix(id: "$42", text: "dopisz", recorded: 1)
        #expect(try await db.tasks().count == 1)
    }
    @Test func retentionIncludesCommandApprovalAndNoticeContent() async throws {
        let db=try Database(url:nil)
        _ = try await db.claimCommand("command")
        try await db.setValue("matrix-command:command","done")
        try await db.enqueue(event:"command",destination:"room",body:"private command result")
        try await db.addApproval(request:"request",run:"run",event:"task",owner:"room",description:"private approval")
        let approval=try #require(try await db.approvals().first)
        try await db.settleApproval(approval.id,state:"once")
        for item in try await db.outbox() { try await db.setDelivery(item.id,state:"delivered") }
        let future=Date().timeIntervalSince1970+9*86400
        try await db.prune(contentDays:7,metadataDays:30,now:future)
        #expect(try await db.outbox().allSatisfy{$0.body.isEmpty})
        #expect(try await db.value("matrix-command:command") == "done")
        try await db.prune(contentDays:7,metadataDays:30,now:future+30*86400)
        #expect(try await db.outbox().isEmpty)
        #expect(try await db.value("matrix-command:command") == nil)
    }
    @Test func crashedMatrixSendRetainsTransactionAndPendingOutput() async throws {
        let db=try Database(url:nil)
        try await db.enqueue(destination:"room",body:"result")
        let item=try #require(try await db.nextDelivery())
        try await db.setDelivery(item.id,state:"sending")
        try await db.recover()
        #expect(try await db.nextDelivery()?.id == item.id)
        #expect(try await db.nextDelivery()?.state == "retry_wait")
        try await db.prune(contentDays:7,metadataDays:30,now:Date().timeIntervalSince1970+40*86400)
        #expect(try await db.nextDelivery()?.body == "result")
    }

}
