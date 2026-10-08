import Foundation
import Testing
import SQLite3
import Darwin
@testable import IndexaCore

struct NotesRecoveryTests {
    @Test func recoveryCannotRaceLiveWriterAndKeepsTombstone() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let id=UUID().uuidString
        var db:OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("indexa-notes.sqlite").path,&db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db,"CREATE TABLE operations(id TEXT PRIMARY KEY,digest TEXT,state TEXT,result TEXT); INSERT INTO operations VALUES('\(id)','digest','pending',NULL)",nil,nil,nil) == SQLITE_OK)
        #expect(try NotesRecovery.pending(profileHome:root) == [id])
        let fd=open(root.appendingPathComponent("indexa-notes.lock").path,O_RDWR)
        defer { close(fd) }
        #expect(flock(fd,LOCK_EX|LOCK_NB) == 0)
        #expect(throws:IndexaError("notes_write_in_progress")) { try NotesRecovery.reviewed([id],profileHome:root) }
        flock(fd,LOCK_UN)
        try NotesRecovery.reviewed([id],profileHome:root)
        #expect(try NotesRecovery.pending(profileHome:root).isEmpty)
        var stmt:OpaquePointer?
        sqlite3_prepare_v2(db,"SELECT state,result FROM operations",-1,&stmt,nil)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(String(cString:sqlite3_column_text(stmt,0)) == "reviewed")
        #expect(String(cString:sqlite3_column_text(stmt,1)).contains("do_not_repeat"))
    }
}
