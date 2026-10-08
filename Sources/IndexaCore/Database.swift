import Foundation
import SQLite3

public struct TaskRecord: Identifiable, Equatable, Sendable {
    public let id, source, text, session, state: String
    public let runID, error: String?
    public let output, deliveryState: String?
    public let created: Double
}
public struct OutboxItem: Identifiable, Sendable {
    public let id, eventID, kind, destination, body, state: String
    public let attempts: Int
    public let nextAttempt: Double
    public let markup: String?
}
public struct Accepted: Sendable { public let id: String; public let duplicate: Bool }
public struct ApprovalRecord: Identifiable, Sendable {
    public let id, requestID, runID, eventID, description, state: String
    public let expires: Double
}

public actor Database {
    private let db: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw IndexaError("database_create") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(url?.path ?? ":memory:", &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw IndexaError("database_open_\(code)")
        }
        db = connection
        sqlite3_busy_timeout(db, 5000)
        let schema = """
        PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY);
        INSERT OR IGNORE INTO schema_migrations VALUES(1);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS inbound_events(
          id TEXT PRIMARY KEY, source TEXT NOT NULL, stable_source_id TEXT NOT NULL,
          recorded_at REAL NOT NULL, received_at REAL NOT NULL, transcript TEXT NOT NULL,
          payload_digest TEXT NOT NULL, conversation_id TEXT NOT NULL, status TEXT NOT NULL,
          UNIQUE(source,stable_source_id));
        CREATE TABLE IF NOT EXISTS tasks(
          event_id TEXT PRIMARY KEY REFERENCES inbound_events(id), hermes_run_id TEXT,
          hermes_session_id TEXT NOT NULL, idempotency_key TEXT NOT NULL UNIQUE,
          state TEXT NOT NULL, started_at REAL, updated_at REAL NOT NULL,
          terminal_error_code TEXT, submit_json TEXT);
        CREATE TABLE IF NOT EXISTS outbox(
          id TEXT PRIMARY KEY, event_id TEXT NOT NULL, kind TEXT NOT NULL, destination TEXT NOT NULL,
          body TEXT NOT NULL, markup TEXT, state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
          next_attempt_at REAL NOT NULL DEFAULT 0, telegram_message_id TEXT, UNIQUE(event_id,kind));
        CREATE INDEX IF NOT EXISTS tasks_state ON tasks(state);
        CREATE INDEX IF NOT EXISTS outbox_state ON outbox(state);
        CREATE TABLE IF NOT EXISTS command_receipts(id TEXT PRIMARY KEY,created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS telegram_cursor(bot TEXT PRIMARY KEY,update_id INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS approvals(
          id TEXT PRIMARY KEY, request_id TEXT NOT NULL, run_id TEXT NOT NULL, event_id TEXT NOT NULL,
          owner TEXT NOT NULL, state TEXT NOT NULL, expiration REAL NOT NULL, description TEXT NOT NULL,
          UNIQUE(run_id,request_id));
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); throw IndexaError("database_migration") }
        // Upgrade existing installations without replacing the database or pending work.
        var columns: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT created_at FROM outbox LIMIT 0", -1, &columns, nil)
        let hasTimestamp = columns != nil
        sqlite3_finalize(columns)
        if !hasTimestamp {
            let migration = "ALTER TABLE outbox ADD COLUMN created_at REAL NOT NULL DEFAULT 0; UPDATE outbox SET created_at=strftime('%s','now'); INSERT OR IGNORE INTO schema_migrations VALUES(2);"
            guard sqlite3_exec(db, migration, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); throw IndexaError("database_migration") }
        }
        var outputColumn:OpaquePointer?
        let hasOutput = sqlite3_prepare_v2(db,"SELECT output FROM tasks LIMIT 0",-1,&outputColumn,nil) == SQLITE_OK
        sqlite3_finalize(outputColumn)
        if !hasOutput {
            guard sqlite3_exec(db,"ALTER TABLE tasks ADD COLUMN output TEXT; INSERT OR IGNORE INTO schema_migrations VALUES(3)",nil,nil,nil) == SQLITE_OK else { sqlite3_close(db);throw IndexaError("database_migration") }
        }
        var deliveryColumn:OpaquePointer?
        let hasDeliveryLink = sqlite3_prepare_v2(db,"SELECT delivery_event FROM tasks LIMIT 0",-1,&deliveryColumn,nil) == SQLITE_OK
        sqlite3_finalize(deliveryColumn)
        if !hasDeliveryLink {
            guard sqlite3_exec(db,"ALTER TABLE tasks ADD COLUMN delivery_event TEXT; INSERT OR IGNORE INTO schema_migrations VALUES(4)",nil,nil,nil) == SQLITE_OK else { sqlite3_close(db);throw IndexaError("database_migration") }
        }
        // Old command tombstones have no timestamp; retain them for one complete metadata window.
        sqlite3_exec(db, "INSERT OR IGNORE INTO command_receipts SELECT substr(key,16),strftime('%s','now') FROM meta WHERE key LIKE 'matrix-command:%'", nil, nil, nil)
    }
    deinit { sqlite3_close(db) }

    private func query(_ sql: String, _ values: [String?] = []) throws -> [[String:String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw IndexaError("database_prepare") }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in values.enumerated() {
            let result = value.map { sqlite3_bind_text(stmt, Int32(i+1), $0, -1, Self.transient) } ?? sqlite3_bind_null(stmt, Int32(i+1))
            guard result == SQLITE_OK else { throw IndexaError("database_bind") }
        }
        var rows = [[String:String]]()
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw IndexaError("database_step_\(result)") }
            var row = [String:String]()
            for i in 0..<sqlite3_column_count(stmt) {
                if let text = sqlite3_column_text(stmt, i) { row[String(cString: sqlite3_column_name(stmt, i))] = String(cString: text) }
            }
            rows.append(row)
        }
    }
    @discardableResult private func transaction<T>(_ body: () throws -> T) throws -> T {
        _ = try query("BEGIN IMMEDIATE")
        do { let value = try body(); _ = try query("COMMIT"); return value }
        catch { _ = try? query("ROLLBACK"); throw error }
    }
    public func value(_ key: String) throws -> String? { try query("SELECT value FROM meta WHERE key=?",[key]).first?["value"] }
    public func setValue(_ key: String, _ value: String) throws { _ = try query("INSERT INTO meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[key,value]) }

    public func beginOrganizerOperation(module: String, operationID: String, digest: String) throws -> String? {
        let key = "organizer-operation:\(module):\(operationID)"
        return try transaction {
            if let saved = try value(key) {
                let receipt = try JSONDecoder().decode([String:String].self, from: Data(saved.utf8))
                guard receipt["digest"] == digest else { throw IndexaError("organizer_operation_conflict") }
                guard let id = receipt["id"] else { throw IndexaError("organizer_write_uncertain") }
                return id
            }
            try setValue(key, String(decoding: JSONEncoder().encode(["digest": digest]), as: UTF8.self))
            return nil
        }
    }

    public func finishOrganizerOperation(module: String, operationID: String, digest: String, itemID: String) throws {
        let key = "organizer-operation:\(module):\(operationID)"
        try transaction {
            guard let saved = try value(key),
                  let receipt = try? JSONDecoder().decode([String:String].self, from: Data(saved.utf8)),
                  receipt == ["digest": digest] else { throw IndexaError("organizer_operation_conflict") }
            try setValue(key, String(decoding: JSONEncoder().encode(["digest": digest, "id": itemID]), as: UTF8.self))
        }
    }
    private func conversation() throws -> String {
        if let current = try value("conversation") { return current }
        let id = "indexa-" + UUID().uuidString
        try setValue("conversation", id)
        return id
    }
    public func bindConversation(_ session:String) throws {
        guard !session.isEmpty,session.count <= 256 else { throw IndexaError("invalid_session_id") }
        try transaction {
            try setValue("conversation",session)
            _ = try query("UPDATE inbound_events SET conversation_id=? WHERE id IN (SELECT event_id FROM tasks WHERE state='queued')",[session])
            _ = try query("UPDATE tasks SET hermes_session_id=? WHERE state='queued'",[session])
        }
    }
    public func newConversation() throws -> String {
        try transaction {
            guard try query("SELECT 1 FROM tasks WHERE state IN ('queued','submitting','running','waiting_for_approval','stopping','needs_review') LIMIT 1").isEmpty else { throw IndexaError("conversation_busy") }
            let id = "indexa-" + UUID().uuidString
            try setValue("conversation", id)
            return id
        }
    }
    private func acceptInside(source: String, sourceID: String, text: String, recorded: Double, digest: String, isTest: Bool) throws -> Accepted {
        if let old = try query("SELECT id,payload_digest FROM inbound_events WHERE source=? AND stable_source_id=?", [source,sourceID]).first {
            guard old["payload_digest"] == digest else { throw IndexaError("delivery_id_conflict") }
            return Accepted(id: old["id"]!, duplicate: true)
        }
        let id = UUID().uuidString, session = try conversation(), now = String(Date().timeIntervalSince1970)
        _ = try query("INSERT INTO inbound_events VALUES(?,?,?,?,?,?,?,?,?)",[id,source,sourceID,String(recorded),now,text,digest,session,isTest ? "test" : "queued"])
        if !isTest { _ = try query("INSERT INTO tasks(event_id,hermes_session_id,idempotency_key,state,updated_at) VALUES(?,?,?,'queued',?)", [id,session,id,now]) }
        return Accepted(id:id,duplicate:false)
    }
    public func accept(source: String, sourceID: String, text: String, recorded: Double, digest: String, isTest: Bool = false) throws -> Accepted {
        try transaction { try acceptInside(source:source,sourceID:sourceID,text:text,recorded:recorded,digest:digest,isTest:isTest) }
    }
    public func ingestMatrix(id:String,text:String,recorded:Double) throws -> Accepted {
        try accept(source:"matrix",sourceID:id,text:text,recorded:recorded,digest:PebbleAuthentication.digest(Data(text.utf8)))
    }
    public func bindMatrix(room:String,user:String,bot:String) throws {
        try transaction {
            if let old=try value("owner_chat"), old != room { throw IndexaError("matrix_room_changed") }
            if let old=try value("owner_user"), old != user { throw IndexaError("matrix_owner_changed") }
            try setValue("owner_chat",room);try setValue("owner_user",user);try setValue("bot_id",bot)
        }
    }
    public func claimCommand(_ id:String) throws -> Bool {
        try transaction {
            let key="matrix-command:"+id
            guard try value(key) == nil else { return false }
            try setValue(key,"processing")
            _ = try query("INSERT OR IGNORE INTO command_receipts VALUES(?,?)",[id,String(Date().timeIntervalSince1970)])
            return true
        }
    }
    private func taskRecords(_ suffix:String, _ values:[String?] = []) throws -> [TaskRecord] {
        try query("SELECT t.*,e.source,e.transcript,e.received_at FROM tasks t JOIN inbound_events e ON e.id=t.event_id " + suffix,values).map { row in
            let deliveries = try query("SELECT body,state FROM outbox WHERE event_id=? AND (kind LIKE 'result:%' OR kind LIKE 'shared-answer:%') ORDER BY rowid",[row["delivery_event"] ?? row["event_id"]])
            return TaskRecord(id:row["event_id"]!,source:row["source"]!,text:row["transcript"]!,session:row["hermes_session_id"]!,state:row["state"]!,runID:row["hermes_run_id"],error:row["terminal_error_code"],output:row["output"] ?? (deliveries.isEmpty ? nil : deliveries.compactMap{$0["body"]}.joined(separator:"\n")),deliveryState:deliveries.first(where:{$0["state"] != "delivered"})?["state"] ?? deliveries.first?["state"],created:Double(row["received_at"]!)!)
        }
    }
    public func tasks() throws -> [TaskRecord] {
        try taskRecords("ORDER BY CASE WHEN t.state IN ('submitting','running','waiting_for_approval','stopping','needs_review') THEN 0 WHEN t.state='queued' THEN 1 ELSE 2 END,e.received_at DESC LIMIT 200")
    }
    public func nextTask() throws -> TaskRecord? {
        guard try query("SELECT 1 FROM tasks WHERE state='needs_review' LIMIT 1").isEmpty else { return nil }
        return try taskRecords("WHERE t.state IN ('queued','submitting','running','waiting_for_approval','stopping') ORDER BY e.received_at,e.rowid LIMIT 1").first
    }
    public func markSubmitting(_ id: String, payload: Data) throws {
        _ = try query("UPDATE tasks SET state='submitting',submit_json=?,started_at=?,updated_at=? WHERE event_id=? AND state='queued'",[String(decoding:payload,as:UTF8.self),String(Date().timeIntervalSince1970),String(Date().timeIntervalSince1970),id])
    }
    public func setRun(_ id: String, run: String, state: String = "running") throws {
        _ = try query("UPDATE tasks SET hermes_run_id=?,state=?,updated_at=? WHERE event_id=?",[run,state,String(Date().timeIntervalSince1970),id])
    }
    public func review(_ id: String, code: String) throws {
        _ = try query("UPDATE tasks SET state='needs_review',terminal_error_code=?,updated_at=? WHERE event_id=?",[code,String(Date().timeIntervalSince1970),id])
    }
    public func resolveReview(_ id: String) throws {
        _ = try query("UPDATE tasks SET state='failed',terminal_error_code='manually_reviewed',updated_at=? WHERE event_id=? AND state='needs_review'",[String(Date().timeIntervalSince1970),id])
    }
    public func recover() throws {
        try transaction {
            _ = try query("UPDATE tasks SET state='needs_review',terminal_error_code='submission_unknown_after_restart' WHERE state='submitting'")
            _ = try query("UPDATE outbox SET state='retry_wait',next_attempt_at=0 WHERE state IN ('sending','delivery_unknown')")
            _ = try query("UPDATE approvals SET state='unknown' WHERE state='resolving'")
        }
    }
    public func finish(_ id: String, state: String, result: String, destination: String, code: String? = nil, deliveryEvent:String? = nil) throws {
        try transaction {
            _ = try query("UPDATE tasks SET state=?,terminal_error_code=?,updated_at=?,output=?,delivery_event=? WHERE event_id=?",[state,code,String(Date().timeIntervalSince1970),result,deliveryEvent,id])
            _ = try query("UPDATE inbound_events SET status=? WHERE id=?",[state,id])
            _ = try query("UPDATE approvals SET state='closed' WHERE event_id=? AND state='pending'",[id])
            try enqueue(event:deliveryEvent ?? id,kind:deliveryEvent == nil ? "result" : "shared-answer",destination:destination,body:result)
        }
    }
    public func enqueue(event: String = UUID().uuidString, kind: String = "notice", destination: String, body: String, markup: String? = nil) throws {
        let parts = MessageParts.split(body)
        for (i, part) in parts.enumerated() {
            let text = parts.count > 1 ? "[\(i+1)/\(parts.count)] \(part)" : part
            _ = try query("INSERT OR IGNORE INTO outbox(id,event_id,kind,destination,body,markup,created_at) VALUES(?,?,?,?,?,?,?)",[UUID().uuidString,event,"\(kind):\(i)",destination,text,i == parts.count-1 ? markup : nil,String(Date().timeIntervalSince1970)])
        }
    }
    private func deliveryRecords(_ suffix:String) throws -> [OutboxItem] {
        try query("SELECT * FROM outbox " + suffix).map {
            OutboxItem(id:$0["id"]!,eventID:$0["event_id"]!,kind:$0["kind"]!,destination:$0["destination"]!,body:$0["body"]!,state:$0["state"]!,attempts:Int($0["attempts"]!)!,nextAttempt:Double($0["next_attempt_at"]!)!,markup:$0["markup"])
        }
    }
    public func outbox() throws -> [OutboxItem] { try deliveryRecords("ORDER BY CASE WHEN state='delivered' THEN 1 ELSE 0 END,rowid DESC LIMIT 200") }
    public func nextDelivery() throws -> OutboxItem? { try deliveryRecords("WHERE state!='delivered' ORDER BY rowid LIMIT 1").first }
    public func setDelivery(_ id: String, state: String, next: Double = 0, messageID: String? = nil) throws {
        _ = try query("UPDATE outbox SET state=?,next_attempt_at=?,telegram_message_id=COALESCE(?,telegram_message_id),attempts=attempts+CASE WHEN ?='sending' THEN 1 ELSE 0 END WHERE id=?",[state,String(next),messageID,state,id])
    }
    public func retryDelivery(_ id: String) throws {
        _ = try query("UPDATE outbox SET state='pending',attempts=0,next_attempt_at=0 WHERE id=? AND state IN ('failed','delivery_unknown')",[id])
    }
    public func approvals() throws -> [ApprovalRecord] {
        try query("SELECT * FROM approvals WHERE state IN ('pending','resolving','unknown')").map {
            ApprovalRecord(id:$0["id"]!,requestID:$0["request_id"]!,runID:$0["run_id"]!,eventID:$0["event_id"]!,description:$0["description"]!,state:$0["state"]!,expires:Double($0["expiration"]!)!)
        }
    }
    public func addApproval(request: String, run: String, event: String, owner: String, description: String) throws {
        try transaction {
            guard try query("SELECT 1 FROM approvals WHERE run_id=? AND request_id=?",[run,request]).isEmpty else { return }
            let id = UUID().uuidString
            _ = try query("INSERT INTO approvals VALUES(?,?,?,?,?,'pending',?,?)",[id,request,run,event,owner,String(Date().timeIntervalSince1970+300),String(description.prefix(1000))])
            try enqueue(event:id,kind:"approval",destination:owner,body:"Indexa potrzebuje zgody (5 min):\n\(String(description.prefix(1000)))\n\nZezwól raz: !approve \(id) once\nOdmów: !approve \(id) deny")
        }
    }
    public func claimApproval(_ id: String, owner: String) throws -> ApprovalRecord {
        try transaction {
            guard let a = try approvals().first(where:{$0.id == id}), a.state == "pending", a.expires > Date().timeIntervalSince1970,
                  try query("SELECT 1 FROM approvals WHERE id=? AND owner=?",[id,owner]).count == 1 else { throw IndexaError("approval_expired_or_used") }
            _ = try query("UPDATE approvals SET state='resolving' WHERE id=?",[id])
            return a
        }
    }
    public func settleApproval(_ id: String, state: String) throws { _ = try query("UPDATE approvals SET state=? WHERE id=?",[state,id]) }
    public func prune(contentDays: Int, metadataDays: Int, now:Double = Date().timeIntervalSince1970) throws {
        try transaction {
            let terminal = "SELECT event_id FROM tasks WHERE state IN ('completed','failed','cancelled','interrupted') AND updated_at < ? AND NOT EXISTS(SELECT 1 FROM outbox o WHERE o.event_id=COALESCE(tasks.delivery_event,tasks.event_id) AND o.state!='delivered')"
            _ = try query("UPDATE inbound_events SET transcript='' WHERE id IN (\(terminal))",[String(now-Double(contentDays)*86400)])
            _ = try query("UPDATE tasks SET submit_json=NULL,output=NULL WHERE event_id IN (\(terminal))",[String(now-Double(contentDays)*86400)])
            _ = try query("UPDATE outbox SET body='',markup=NULL WHERE state='delivered' AND event_id IN (\(terminal))",[String(now-Double(contentDays)*86400)])
            _ = try query("UPDATE outbox SET body='',markup=NULL WHERE state='delivered' AND created_at < ?",[String(now-Double(contentDays)*86400)])
            _ = try query("UPDATE approvals SET description='' WHERE state NOT IN ('pending','resolving','unknown') AND expiration < ?",[String(now-Double(contentDays)*86400)])
            _ = try query("DELETE FROM outbox WHERE state='delivered' AND created_at < ?",[String(now-Double(metadataDays)*86400)])
            _ = try query("DELETE FROM meta WHERE key IN (SELECT 'matrix-command:'||id FROM command_receipts WHERE created_at < ?)",[String(now-Double(metadataDays)*86400)])
            _ = try query("DELETE FROM command_receipts WHERE created_at < ?",[String(now-Double(metadataDays)*86400)])
            _ = try query("UPDATE inbound_events SET transcript='' WHERE status='test' AND received_at < ?",[String(now-Double(contentDays)*86400)])
            // Keep source IDs/digests as dedupe tombstones for the configured metadata window.
            _ = try query("DELETE FROM approvals WHERE state NOT IN ('pending','resolving','unknown') AND expiration < ?",[String(now-Double(metadataDays)*86400)])
            _ = try query("DELETE FROM outbox WHERE state='delivered' AND event_id IN (\(terminal))",[String(now-Double(metadataDays)*86400)])
            _ = try query("DELETE FROM tasks WHERE event_id IN (\(terminal))",[String(now-Double(metadataDays)*86400)])
            _ = try query("DELETE FROM inbound_events WHERE received_at < ? AND NOT EXISTS(SELECT 1 FROM tasks WHERE event_id=inbound_events.id)",[String(now-Double(metadataDays)*86400)])
        }
    }
}

public enum MessageParts {
    public static func split(_ text: String, limit: Int = 3900) -> [String] {
        guard !text.isEmpty else { return ["Brak odpowiedzi tekstowej. Sprawdź stan zadania w Indexa."] }
        var chunks = [String](), part = "", count = 0
        // Unicode scalars preserve surrogate pairs; the limit is conservative in UTF-16 units.
        for scalar in text.unicodeScalars {
            let size = scalar.utf16.count
            if count + size > limit { chunks.append(part); part = ""; count = 0 }
            part.unicodeScalars.append(scalar); count += size
        }
        if !part.isEmpty { chunks.append(part) }
        return chunks
    }
}
