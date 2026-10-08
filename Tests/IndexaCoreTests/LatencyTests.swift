import Foundation
import SQLite3
import Testing
@testable import IndexaCore

struct LatencyTests {
    private func execute(_ url:URL,_ sql:String) throws -> String? {
        var db:OpaquePointer?
        guard sqlite3_open(url.path,&db) == SQLITE_OK,let db else { throw IndexaError("test_open") }
        defer { sqlite3_close(db) }
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK,let statement else { throw IndexaError("test_prepare") }
        defer { sqlite3_finalize(statement) }
        let result=sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw IndexaError("test_execute") }
        return result == SQLITE_ROW ? sqlite3_column_text(statement,0).map { String(cString:$0) } : nil
    }

    @Test func stagesPersistWithoutContentAndDeliveryLinksBeforeAndAfterFinish() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("latency.sqlite"),db=try Database(url:url)
        let content="private message Bearer-secret https://private.example/path"
        let task=try await db.accept(source:"pebble",sourceID:"source-secret",text:content,recorded:Date().timeIntervalSince1970-2,digest:"digest-secret")
        _ = try await db.accept(source:"pebble",sourceID:"source-secret",text:content,recorded:1,digest:"digest-secret")
        _ = try await db.accept(source:"pebble",sourceID:"probe",text:content,recorded:1,digest:"probe",isTest:true)
        await db.recordLatency(event:task.id,stage:.submission,seconds:0.0125,status:202)
        let delivery="hermes-message:private-delivery-locator"
        await db.recordLatency(event:delivery,stage:.delivery,seconds:0.3,status:503)
        try await db.finish(task.id,state:"completed",result:content,destination:"private-room",deliveryEvent:delivery)
        await db.recordLatency(event:delivery,stage:.delivery,seconds:0.125,status:200)
        await db.recordLatency(event:content,stage:.history,seconds:.nan)
        let report=try await db.latencyReport()
        #expect(report.components(separatedBy:"stage=received").count-1 == 1)
        #expect(report.contains("stage=upstream_age"))
        #expect(report.contains("not network latency"))
        #expect(report.contains("ms=12.500 status=202"))
        let deliveries=report.split(separator:"\n").filter { $0.contains("stage=delivery") }
        #expect(deliveries.count == 2)
        #expect(deliveries.allSatisfy { $0.contains("source=pebble event=\(task.id)") })
        #expect(report.contains("stage=history ms=-"))
        for secret in [content,"source-secret","digest-secret",delivery,"private-room","private.example"] { #expect(!report.contains(secret)) }
        let restarted=try Database(url:url)
        #expect(try await restarted.latencyReport() == report)
    }

    @Test func journalIsBoundedByAgeCountAndReportWindow() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("latency.sqlite"),db=try Database(url:url)
        let task=try await db.ingestMatrix(id:"incoming",text:"private request",recorded:1)
        _ = try execute(url,"INSERT INTO latency_events(event_id,stage,timestamp) VALUES('old','history',0)")
        _ = try execute(url,"WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<10002) INSERT INTO latency_events(event_id,stage,timestamp,seconds) SELECT 'synthetic','history',strftime('%s','now'),i FROM n")
        await db.recordLatency(event:task.id,stage:.statusPoll,seconds:0.75,status:200)
        #expect(try execute(url,"SELECT count(*) FROM latency_events") == "10000")
        #expect(try execute(url,"SELECT count(*) FROM latency_events WHERE timestamp=0") == "0")
        #expect(try await db.latencyReport().split(separator:"\n").filter { $0.contains(" stage=") }.count == 200)
        try await db.prune(contentDays:7,metadataDays:30,now:Date().timeIntervalSince1970+8*86400)
        #expect(try execute(url,"SELECT count(*) FROM latency_events") == "0")
    }

    @Test func brokenOrBusyJournalDoesNotBlockTaskOperations() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("latency.sqlite"),db=try Database(url:url)
        let task=try await db.ingestMatrix(id:"first",text:"message",recorded:1)
        var writer:OpaquePointer?
        #expect(sqlite3_open(url.path,&writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK)
        let start=Date()
        await db.recordLatency(event:task.id,stage:.preparation,seconds:1)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(sqlite3_exec(writer,"ROLLBACK",nil,nil,nil) == SQLITE_OK)
        #expect(try execute(url,"SELECT count(*) FROM latency_events WHERE stage='preparation'") == "0")
        _ = try execute(url,"DROP TABLE latency_events")
        let accepted=try await db.ingestMatrix(id:"second",text:"message",recorded:1)
        await db.recordLatency(event:accepted.id,stage:.hermes,seconds:1)
        #expect(try await db.tasks().count == 2)
        try await db.markSubmitting(accepted.id,payload:Data("{}".utf8))
        #expect(try await db.tasks().first(where:{$0.id==accepted.id})?.state == "submitting")
    }
}
