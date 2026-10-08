import Foundation
import EventKit
import CryptoKit

public enum OrganizerKind: String, Sendable, CaseIterable {
    case reminders, calendar
    public var title: String { self == .calendar ? "Kalendarz" : "Przypomnienia" }
    var entity: EKEntityType { self == .calendar ? .event : .reminder }
}

public struct OrganizerMCP: MCPModule {
    public let kind: OrganizerKind
    private let store: OrganizerStore
    public var id: String { kind.rawValue }
    public var title: String { kind.title }
    public var permissionKeys: Set<String> { kind == .calendar ? ["read", "create"] : ["read", "create", "complete"] }
    public init(kind: OrganizerKind, store: OrganizerStore) { self.kind = kind; self.store = store }

    public func tools() async throws -> [MCPTool] {
        let text: MCPValue = .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(2000)])
        let date: MCPValue = .object(["type": .string("string"), "format": .string("date-time"), "description": .string("ISO 8601 with explicit timezone offset, e.g. 2026-10-08T09:00:00+02:00")])
        func tool(_ suffix: String, _ description: String, _ properties: [String: MCPValue], _ required: [String], _ grant: String) -> MCPTool {
            .init(name: id + "_" + suffix, description: description, inputSchema: .object([
                "type": .string("object"), "properties": .object(properties), "required": .array(required.map(MCPValue.string)), "additionalProperties": .bool(false)
            ]), requiredPermissions: [grant])
        }
        let writeHelp = " Requires UUID operation_id. Reuse it for retries; never retry an uncertain write with a new UUID. Only verified=true confirms saving locally; iCloud sync is separate."
        var tools = [tool("lists", "List all existing \(kind == .calendar ? "calendars" : "reminder lists"), including their IDs and whether they allow writes.", [:], [], "read")]
        if kind == .calendar {
            tools += [
                tool("events", "Read existing events across ALL calendars by default, including holidays and time off. Required date range, max 366 days; at most 200 matches. Optional calendar_id narrows to one calendar. query filters titles; truncated=true requires a narrower range/query.", ["start": date, "end": date, "calendar_id": text, "query": text], ["start", "end"], "read"),
                tool("create", "Create a timed event in an existing writable calendar; omit calendar_id to use the system default. No invitations, deletion or recurrence." + writeHelp, ["title": text, "start": date, "end": date, "calendar_id": text, "operation_id": text, "notes": text, "location": text, "alert_minutes": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(10080)])], ["title", "start", "end", "operation_id"], "create")
            ]
        } else {
            tools += [
                tool("list", "Read incomplete reminders across ALL existing lists by default, max 200 matches. query filters titles. truncated=true requires a narrower query/list. Set include_completed=true to include completed reminders.", ["calendar_id": text, "query": text, "include_completed": .object(["type": .string("boolean")])], [], "read"),
                tool("create", "Create a reminder in an existing list; omit calendar_id to use the system default. Optional due creates a due date and notification; this is NOT an iPhone Clock alarm." + writeHelp, ["title": text, "notes": text, "due": date, "calendar_id": text, "operation_id": text], ["title", "operation_id"], "create"),
                tool("complete", "Mark an existing reminder completed by exact reminder_id. Do not delete it." + writeHelp, ["reminder_id": text, "operation_id": text], ["reminder_id", "operation_id"], "complete")
            ]
        }
        return tools
    }

    public func call(tool: String, arguments: MCPValue) async throws -> MCPToolResult {
        do {
            try Self.validate(kind: kind, tool: tool, arguments: arguments)
            return try await store.perform(kind: kind, tool: tool, arguments: arguments)
        } catch {
            let code = (error as? IndexaError)?.code ?? "organizer_unavailable"
            let descriptions = [
                "invalid_organizer_request": "Hermes przekazał nieprawidłowe dane lub daty. Wymagana jest jawna strefa czasowa.",
                "organizer_access_required": "Wymagana zgoda macOS. Otwórz dostęp i szczegóły tej integracji.",
                "organizer_target_missing": "Nie znaleziono wskazanego kalendarza, listy lub przypomnienia. Odśwież ich listę.",
                "organizer_read_only": "Wybrany kalendarz lub lista nie pozwala na zapisywanie zmian.",
                "organizer_operation_conflict": "Identyfikator operacji został już użyty do innej zmiany.",
                "organizer_write_uncertain": "Nie potwierdzono zapisu. Sprawdź wpis w aplikacji przed ponowieniem.",
                "organizer_busy": "Trwa poprzedni zapis. Poczekaj na jego zakończenie."
            ]
            let diagnostic = descriptions[code] ?? "Nie udało się wykonać operacji. Sprawdź dostęp do aplikacji w ustawieniach macOS."
            let safeCode = descriptions[code] == nil ? "organizer_unavailable" : code
            let data = try JSONEncoder().encode(MCPValue.object(["error": .string(safeCode), "needs_review": .bool(safeCode == "organizer_write_uncertain")]))
            return .text(String(decoding: data, as: UTF8.self), isError: true, diagnostic: diagnostic)
        }
    }

    static func date(_ raw: String) -> Date? {
        guard raw.count <= 40, raw.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }

    static func validate(kind: OrganizerKind, tool: String, arguments: MCPValue) throws {
        func invalid() throws -> Never { throw IndexaError("invalid_organizer_request") }
        guard case .object(let args) = arguments else { try invalid() }
        let allowed: Set<String>, required: Set<String>
        switch (kind, tool) {
        case (_, kind.rawValue + "_lists"): allowed = []; required = []
        case (.calendar, "calendar_events"): allowed = ["start", "end", "calendar_id", "query"]; required = ["start", "end"]
        case (.calendar, "calendar_create"): allowed = ["title", "start", "end", "calendar_id", "operation_id", "notes", "location", "alert_minutes"]; required = ["title", "start", "end", "operation_id"]
        case (.reminders, "reminders_list"): allowed = ["calendar_id", "query", "include_completed"]; required = []
        case (.reminders, "reminders_create"): allowed = ["title", "notes", "due", "calendar_id", "operation_id"]; required = ["title", "operation_id"]
        case (.reminders, "reminders_complete"): allowed = ["reminder_id", "operation_id"]; required = ["reminder_id", "operation_id"]
        default: try invalid()
        }
        guard Set(args.keys).isSubset(of: allowed), required.isSubset(of: Set(args.keys)) else { try invalid() }
        for (key, value) in args {
            if key == "include_completed" { guard case .bool = value else { try invalid() }; continue }
            if key == "alert_minutes" { guard case .number(let number) = value, number.isFinite, number.rounded() == number, (0...10080).contains(number) else { try invalid() }; continue }
            guard let text = value.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000 else { try invalid() }
            if key == "operation_id", UUID(uuidString: text) == nil { try invalid() }
            if ["start", "end", "due"].contains(key), date(text) == nil { try invalid() }
        }
        if let start = args["start"]?.stringValue.flatMap(date), let end = args["end"]?.stringValue.flatMap(date) {
            guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else { try invalid() }
        }
    }
}

@MainActor public final class OrganizerStore {
    private let events = EKEventStore()
    private let database: Database
    private var writing = false
    public init(database: Database) { self.database = database }

    public func accessIssue(_ kind: OrganizerKind) -> String? {
        switch EKEventStore.authorizationStatus(for: kind.entity) {
        case .fullAccess: return nil
        case .notDetermined: return "Wymagana zgoda macOS"
        default: return "Brak dostępu w macOS"
        }
    }
    public func requestAccess(_ kind: OrganizerKind) async throws -> Bool {
        if kind == .calendar { return try await events.requestFullAccessToEvents() }
        return try await events.requestFullAccessToReminders()
    }

    func perform(kind: OrganizerKind, tool: String, arguments: MCPValue) async throws -> MCPToolResult {
        guard accessIssue(kind) == nil else { throw IndexaError("organizer_access_required") }
        let args = arguments
        let calendars = events.calendars(for: kind.entity)
        let selected: [EKCalendar]
        if let id = args["calendar_id"]?.stringValue {
            selected = calendars.filter { $0.calendarIdentifier == id }
            guard !selected.isEmpty else { throw IndexaError("organizer_target_missing") }
        } else { selected = calendars }
        if tool.hasSuffix("_lists") {
            return try result(.object(["lists": .array(calendars.map { .object([
                "id": .string($0.calendarIdentifier), "title": .string($0.title), "account": .string($0.source.title), "writable": .bool($0.allowsContentModifications)
            ]) })]))
        }
        if tool == "calendar_events" {
            let predicate = events.predicateForEvents(withStart: OrganizerMCP.date(args["start"]!.stringValue!)!, end: OrganizerMCP.date(args["end"]!.stringValue!)!, calendars: selected)
            let matching = events.events(matching: predicate).filter { matches($0.title, query: args["query"]?.stringValue) }.sorted { $0.startDate < $1.startDate }
            return try result(.object(["events": .array(matching.prefix(200).map(eventValue)), "truncated": .bool(matching.count > 200), "timezone": .string(TimeZone.current.identifier)]))
        }
        if tool == "reminders_list" {
            let predicate = events.predicateForReminders(in: selected)
            let found: [EKReminder]? = await withCheckedContinuation { continuation in
                events.fetchReminders(matching: predicate) { continuation.resume(returning: $0) }
            }
            guard let found else { throw IndexaError("organizer_unavailable") }
            let matching = found.filter { (args["include_completed"] == .bool(true) || !$0.isCompleted) && matches($0.title, query: args["query"]?.stringValue) }
                .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            return try result(.object(["reminders": .array(matching.prefix(200).map(reminderValue)), "truncated": .bool(matching.count > 200)]))
        }
        // One native store serializes writes; persisted receipts contain IDs/digests, never titles or notes.
        guard !writing else { throw IndexaError("organizer_busy") }
        writing = true
        defer { writing = false }
        let operation = UUID(uuidString: args["operation_id"]!.stringValue!)!.uuidString
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(.object(["tool": .string(tool), "args": args]) as MCPValue)).map { String(format: "%02x", $0) }.joined()
        let target = args["calendar_id"] == nil ? (kind == .calendar ? events.defaultCalendarForNewEvents : events.defaultCalendarForNewReminders()) : selected.first
        let item: EKCalendarItem
        if tool == "reminders_complete" {
            guard let reminder = events.calendarItem(withIdentifier: args["reminder_id"]!.stringValue!) as? EKReminder else { throw IndexaError("organizer_target_missing") }
            item = reminder
        } else {
            guard let target else { throw IndexaError("organizer_target_missing") }
            if kind == .calendar {
                let event = EKEvent(eventStore: events)
                event.startDate = OrganizerMCP.date(args["start"]!.stringValue!)!
                event.endDate = OrganizerMCP.date(args["end"]!.stringValue!)!
                event.timeZone = TimeZone.current
                event.location = args["location"]?.stringValue
                if case .number(let minutes) = args["alert_minutes"] { event.addAlarm(EKAlarm(relativeOffset: -minutes * 60)) }
                item = event
            } else {
                let reminder = EKReminder(eventStore: events)
                if let due = args["due"]?.stringValue.flatMap(OrganizerMCP.date) {
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone.current
                    reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .timeZone], from: due)
                    reminder.addAlarm(EKAlarm(absoluteDate: due))
                }
                item = reminder
            }
            item.calendar = target; item.title = args["title"]!.stringValue!; item.notes = args["notes"]?.stringValue
        }
        guard item.calendar.allowsContentModifications else { throw IndexaError("organizer_read_only") }
        if let id = try await database.beginOrganizerOperation(module: kind.rawValue, operationID: operation, digest: digest) {
            return try result(.object(["id": .string(id), "verified": .bool(true), "replayed": .bool(true)]))
        }
        do {
            if let reminder = item as? EKReminder {
                if tool == "reminders_complete" { reminder.isCompleted = true }
                try events.save(reminder, commit: true)
            } else if let event = item as? EKEvent { try events.save(event, span: .thisEvent, commit: true) }
            let id = item.calendarItemIdentifier
            guard let saved = events.calendarItem(withIdentifier: id), saved.calendar.calendarIdentifier == item.calendar.calendarIdentifier,
                  saved.title == item.title else { throw IndexaError("organizer_write_uncertain") }
            if tool == "reminders_complete", (saved as? EKReminder)?.isCompleted != true { throw IndexaError("organizer_write_uncertain") }
            if let event = saved as? EKEvent, let original = item as? EKEvent {
                guard event.startDate == original.startDate, event.endDate == original.endDate, event.location == original.location else { throw IndexaError("organizer_write_uncertain") }
                if case .number(let minutes) = args["alert_minutes"], event.alarms?.contains(where: { $0.relativeOffset == -minutes * 60 }) != true { throw IndexaError("organizer_write_uncertain") }
            }
            if let reminder = saved as? EKReminder, let due = args["due"]?.stringValue.flatMap(OrganizerMCP.date) {
                guard let storedDue = dueDate(reminder), abs(storedDue.timeIntervalSince(due)) < 1,
                      reminder.alarms?.contains(where: { $0.absoluteDate.map { abs($0.timeIntervalSince(due)) < 1 } == true }) == true else { throw IndexaError("organizer_write_uncertain") }
            }
            if tool.hasSuffix("_create"), saved.notes != item.notes { throw IndexaError("organizer_write_uncertain") }
            try await database.finishOrganizerOperation(module: kind.rawValue, operationID: operation, digest: digest, itemID: id)
            return try result(.object(["id": .string(id), "verified": .bool(true)]))
        } catch { throw IndexaError("organizer_write_uncertain") }
    }
    private func matches(_ title: String?, query: String?) -> Bool { query.map { (title ?? "").localizedStandardContains($0) } ?? true }
    private func eventValue(_ event: EKEvent) -> MCPValue {
        .object(["id": .string(event.calendarItemIdentifier), "title": .string(event.title ?? ""), "calendar": .string(event.calendar.title), "calendar_id": .string(event.calendar.calendarIdentifier), "start": .string(event.startDate.ISO8601Format()), "end": .string(event.endDate.ISO8601Format()), "all_day": .bool(event.isAllDay), "location": .string(event.location ?? ""), "notes": .string(String((event.notes ?? "").prefix(2000))), "notes_truncated": .bool((event.notes?.count ?? 0) > 2000)])
    }
    private func reminderValue(_ reminder: EKReminder) -> MCPValue {
        .object(["id": .string(reminder.calendarItemIdentifier), "title": .string(reminder.title ?? ""), "list": .string(reminder.calendar.title), "calendar_id": .string(reminder.calendar.calendarIdentifier), "completed": .bool(reminder.isCompleted), "due": dueDate(reminder).map { .string($0.ISO8601Format()) } ?? .null, "due_has_time": .bool(reminder.dueDateComponents?.hour != nil), "notes": .string(String((reminder.notes ?? "").prefix(2000))), "notes_truncated": .bool((reminder.notes?.count ?? 0) > 2000)])
    }
    private func dueDate(_ reminder: EKReminder) -> Date? { reminder.dueDateComponents.flatMap { Calendar(identifier: .gregorian).date(from: $0) } }
    private func result(_ value: MCPValue) throws -> MCPToolResult { .text(String(decoding: try JSONEncoder().encode(value), as: UTF8.self)) }
}
