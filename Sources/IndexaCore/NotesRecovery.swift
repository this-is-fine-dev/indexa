import Foundation
import SQLite3
import Darwin

/// Human-only recovery. Reviewed operation IDs stay as tombstones and are never replayed.
public enum NotesRecovery {
    public static func pending(profileHome:URL) throws -> [String] {
        try access(profileHome:profileHome) { db in
            var stmt:OpaquePointer?
            guard sqlite3_prepare_v2(db,"SELECT id FROM operations WHERE state='pending' ORDER BY rowid",-1,&stmt,nil) == SQLITE_OK else { throw IndexaError("notes_ledger_read") }
            defer { sqlite3_finalize(stmt) }
            var ids=[String]()
            while true {
                let result=sqlite3_step(stmt)
                if result == SQLITE_DONE { return ids }
                guard result == SQLITE_ROW,let id=sqlite3_column_text(stmt,0) else { throw IndexaError("notes_ledger_read") }
                ids.append(String(cString:id))
            }
        } ?? []
    }
    public static func reviewed(_ ids:[String],profileHome:URL) throws {
        guard !ids.isEmpty,ids.allSatisfy({UUID(uuidString:$0) != nil}) else { throw IndexaError("notes_review_invalid") }
        _ = try access(profileHome:profileHome) { db in
            guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK else { throw IndexaError("notes_review_busy") }
            do {
                for id in ids {
                    var stmt:OpaquePointer?
                    guard sqlite3_prepare_v2(db,"UPDATE operations SET state='reviewed',result='{\"error\":\"operation_manually_reviewed_do_not_repeat\",\"reviewed\":true}' WHERE id=? AND state='pending'",-1,&stmt,nil) == SQLITE_OK else { throw IndexaError("notes_ledger_write") }
                    defer { sqlite3_finalize(stmt) }
                    _ = id.withCString { sqlite3_bind_text(stmt,1,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw IndexaError("notes_ledger_write") }
                }
                guard sqlite3_exec(db,"COMMIT",nil,nil,nil) == SQLITE_OK else { throw IndexaError("notes_ledger_write") }
            } catch { sqlite3_exec(db,"ROLLBACK",nil,nil,nil);throw error }
        }
    }
    private static func access<T>(profileHome:URL,_ body:(OpaquePointer)throws->T) throws -> T? {
        let path=profileHome.appendingPathComponent("indexa-notes.sqlite")
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        let fd=open(profileHome.appendingPathComponent("indexa-notes.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw IndexaError("notes_ledger_lock") }
        defer { close(fd) }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { throw IndexaError("notes_write_in_progress") }
        defer { flock(fd,LOCK_UN) }
        var db:OpaquePointer?
        guard sqlite3_open_v2(path.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK,let db else { if let db { sqlite3_close(db) };throw IndexaError("notes_ledger_open") }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db,2000)
        return try body(db)
    }
}
