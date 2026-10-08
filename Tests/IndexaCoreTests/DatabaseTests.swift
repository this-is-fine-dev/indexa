import Foundation
import Testing
import SQLite3
@testable import IndexaCore

struct DatabaseTests {
    @Test func pebbleTranscriptIsQueuedOnReceiptOnceBeforeAnswer() async throws {
        let db = try Database(url:nil)
        try await db.setValue("owner_chat","room")
        let accepted = try await db.accept(source:"pebble",sourceID:"recording",text:"Kiedy mam urlop?",recorded:1,digest:"recording")
        let echo = try #require(try await db.nextDelivery())
        #expect(echo.eventID == accepted.id)
        #expect(echo.kind == "transcript:0")
        #expect(echo.destination == "room")
        #expect(echo.body == "🎙️ Z pierścienia\nKiedy mam urlop?")
        _ = try await db.accept(source:"pebble",sourceID:"recording",text:"Kiedy mam urlop?",recorded:1,digest:"recording")
        _ = try await db.accept(source:"pebble",sourceID:"test",text:"test",recorded:1,digest:"test",isTest:true)
        _ = try await db.ingestMatrix(id:"matrix",text:"Cześć",recorded:1)
        try await db.recover()
        #expect(try await db.outbox().count == 1)
        try await db.finish(accepted.id,state:"completed",result:"W listopadzie",destination:"room")
        #expect(try await db.nextDelivery()?.id == echo.id)
        try await db.setDelivery(echo.id,state:"delivered")
        #expect(try await db.nextDelivery()?.body == "W listopadzie")
    }
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

    @Test func upgradesOriginalOutboxWithoutLosingPendingDelivery() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path=directory.appendingPathComponent("v1.sqlite")
        var old:OpaquePointer?
        #expect(sqlite3_open(path.path,&old) == SQLITE_OK)
        let schema="""
        CREATE TABLE outbox(id TEXT PRIMARY KEY,event_id TEXT NOT NULL,kind TEXT NOT NULL,destination TEXT NOT NULL,body TEXT NOT NULL,markup TEXT,state TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,next_attempt_at REAL NOT NULL DEFAULT 0,telegram_message_id TEXT,UNIQUE(event_id,kind));
        INSERT INTO outbox(id,event_id,kind,destination,body) VALUES('old-txn','old-event','notice:0','room','unsent content');
        CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        INSERT INTO meta VALUES('matrix-command:old','done');
        """
        #expect(sqlite3_exec(old,schema,nil,nil,nil) == SQLITE_OK)
        sqlite3_close(old)
        let upgraded=try Database(url:path)
        #expect(try await upgraded.nextDelivery()?.id == "old-txn")
        #expect(try await upgraded.nextDelivery()?.body == "unsent content")
        try await upgraded.prune(contentDays:7,metadataDays:30,now:Date().timeIntervalSince1970+40*86400)
        #expect(try await upgraded.nextDelivery()?.body == "unsent content")
        #expect(try await upgraded.value("matrix-command:old") == nil)
    }

    @Test func linkedMirrorDeliveryIsSharedAndRetainedUntilSent() async throws {
        let db=try Database(url:nil)
        let task=try await db.accept(source:"matrix",sourceID:"incoming",text:"request",recorded:1,digest:"digest")
        let event="hermes-message:synthetic-answer"
        // Mirror wins the race, then worker completes; both share one stable delivery.
        try await db.enqueue(event:event,kind:"shared-answer",destination:"room",body:"answer")
        try await db.finish(task.id,state:"completed",result:"answer",destination:"room",deliveryEvent:event)
        #expect(try await db.outbox().count == 1)
        #expect(try await db.tasks().first?.deliveryState == "pending")
        try await db.prune(contentDays:7,metadataDays:30,now:Date().timeIntervalSince1970+40*86400)
        #expect(try await db.tasks().first?.output == "answer")
        let delivery=try #require(try await db.nextDelivery())
        try await db.setDelivery(delivery.id,state:"delivered")
        #expect(try await db.tasks().first?.deliveryState == "delivered")
        try await db.prune(contentDays:7,metadataDays:30,now:Date().timeIntervalSince1970+9*86400)
        #expect(try await db.tasks().first?.output == "")
        #expect(try await db.outbox().first?.body == "")
    }

}
