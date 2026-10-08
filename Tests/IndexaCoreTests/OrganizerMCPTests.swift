import Foundation
import EventKit
import Testing
@testable import IndexaCore

struct OrganizerMCPTests {
    @Test func validatesDateRangesTargetsAndSeparateWritePermissions() async throws {
        let query: MCPValue = .object(["start": .string("2026-10-01T00:00:00+02:00"), "end": .string("2026-11-01T00:00:00+01:00"), "query": .string("urlop")])
        try OrganizerMCP.validate(kind: .calendar, tool: "calendar_events", arguments: query)
        for field in ["limit", "offset", "include_notes"] {
            let values: [MCPValue] = field == "include_notes" ? [.number(1), .string("true")] : [.number(-1), .number(1.5), .number(1000001), .string("20")]
            for value in values {
                let invalid: MCPValue = .object(["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-11-01T00:00:00Z"), field: value])
                #expect(throws: IndexaError.self) { try OrganizerMCP.validate(kind: .calendar, tool: "calendar_events", arguments: invalid) }
            }
        }
        try OrganizerMCP.validate(kind: .calendar, tool: "calendar_events", arguments: .object(["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-11-01T00:00:00Z"), "limit": .number(50), "offset": .number(100), "include_notes": .bool(true)]))
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

    @Test @MainActor func calendarPagesStayCompactSearchNotesAndKeepOccurrencesDistinct() throws {
        let store = EKEventStore()
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Synthetic"
        let start = try #require(OrganizerMCP.date("2026-11-01T10:00:00+01:00"))
        let events = (0..<55).map { index in
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = "Recurring item"
            event.startDate = start.addingTimeInterval(Double(index) * 3600)
            event.endDate = event.startDate.addingTimeInterval(1800)
            event.notes = String(repeating: "Long meeting description ", count: 200) + (index == 30 ? " urlop " : "")
            event.location = index == 40 ? "Zakopane" : "Office"
            return event
        }
        let zone = try #require(TimeZone(identifier: "Europe/Warsaw"))
        let first = OrganizerStore.calendarPage(events, arguments: .object([:]), now: start, timezone: zone)
        let encoded = try JSONEncoder().encode(first)
        #expect(encoded.count < 20_000)
        guard case .array(let page) = first["events"] else { Issue.record("Missing events"); return }
        #expect(page.count == 20)
        #expect(page.allSatisfy { $0["notes"] == nil })
        #expect(first["total"] == .number(55))
        #expect(first["next_offset"] == .number(20))
        #expect(first["now"] == .string("2026-11-01T10:00:00+01:00"))
        #expect(first["local_date"] == .string("2026-11-01"))
        #expect(Set(page.compactMap { $0["occurrence_id"]?.stringValue }).count == page.count)
        let last = OrganizerStore.calendarPage(events, arguments: .object(["offset": .number(50), "limit": .number(20)]))
        guard case .array(let tail) = last["events"] else { Issue.record("Missing last page"); return }
        #expect(tail.count == 5)
        #expect(last["next_offset"] == .null && last["truncated"] == .bool(false))
        let notes = OrganizerStore.calendarPage(events, arguments: .object(["query": .string("urlop"), "include_notes": .bool(true)]))
        guard case .array(let found) = notes["events"] else { Issue.record("Missing search results"); return }
        #expect(found.count == 1)
        #expect(found.first?["notes_truncated"] == .bool(true))
        let location = OrganizerStore.calendarPage(events, arguments: .object(["query": .string("zakopane")]))
        #expect(location["total"] == .number(1))
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
