import Foundation
import Testing
@testable import IndexaCore

struct OrganizerMCPTests {
    @Test func validatesDateRangesTargetsAndSeparateWritePermissions() async throws {
        let query: MCPValue = .object(["start": .string("2026-10-01T00:00:00+02:00"), "end": .string("2026-11-01T00:00:00+01:00"), "query": .string("urlop")])
        try OrganizerMCP.validate(kind: .calendar, tool: "calendar_events", arguments: query)
        #expect(OrganizerMCP.date("2026-10-08T09:00:00") == nil)
        #expect(OrganizerMCP.date("2026-10-08T09:00:00.123+02:00") != nil)
        for args: MCPValue in [
            .object(["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-09-01T00:00:00Z")]),
            .object(["start": .string("2026-10-01T00:00:00Z"), "end": .string("2028-10-01T00:00:00Z")]),
            .object(["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-10-02T00:00:00Z"), "delete": .bool(true)])
        ] {
            #expect(throws: IndexaError.self) { try OrganizerMCP.validate(kind: .calendar, tool: "calendar_events", arguments: args) }
        }
        #expect(throws: IndexaError.self) { try OrganizerMCP.validate(kind: .reminders, tool: "reminders_complete", arguments: .object(["reminder_id": .string("existing")])) }
        try OrganizerMCP.validate(kind: .reminders, tool: "reminders_create", arguments: .object(["title": .string("Test"), "operation_id": .string(UUID().uuidString), "due": .string("2026-10-08T18:00:00+02:00")]))
        let database = try Database(url: nil)
        let store = await OrganizerStore(database: database)
        let calendar = OrganizerMCP(kind: .calendar, store: store)
        let reminders = OrganizerMCP(kind: .reminders, store: store)
        let tools = try await calendar.tools()
        #expect(tools.first { $0.name == "calendar_events" }?.inputSchema["required"] == .array([.string("start"), .string("end")]))
        #expect(tools.map(\.requiredPermissions) == [["read"], ["read"], ["create"]])
        #expect(try await reminders.tools().map(\.requiredPermissions) == [["read"], ["read"], ["create"], ["complete"]])
        let manager = try MCPManager(token: String(repeating: "a", count: 64), modules: [calendar, reminders])
        #expect(await manager.snapshots().allSatisfy { !$0.enabled && $0.permissions.isEmpty })
        await manager.stop()
    }

    @Test func writeReceiptsPreventDuplicatesConflictsAndReplayAfterCrash() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.sqlite")
        let db = try Database(url: url)
        let id = UUID().uuidString
        #expect(try await db.beginOrganizerOperation(module: "calendar", operationID: id, digest: "digest") == nil)
        do {
            _ = try await db.beginOrganizerOperation(module: "calendar", operationID: id, digest: "digest")
            Issue.record("Pending writes must not be repeated")
        } catch { #expect((error as? IndexaError)?.code == "organizer_write_uncertain") }
        try await db.finishOrganizerOperation(module: "calendar", operationID: id, digest: "digest", itemID: "saved-event")
        let restored = try Database(url: url)
        #expect(try await restored.beginOrganizerOperation(module: "calendar", operationID: id, digest: "digest") == "saved-event")
        do {
            _ = try await restored.beginOrganizerOperation(module: "calendar", operationID: id, digest: "other")
            Issue.record("Same ID must not authorize a different write")
        } catch { #expect((error as? IndexaError)?.code == "organizer_operation_conflict") }
        #expect(try await restored.beginOrganizerOperation(module: "reminders", operationID: id, digest: "other") == nil)
    }
}
