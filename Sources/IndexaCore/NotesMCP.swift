import Foundation
import Darwin

/// Uses the same exact-ID, read-back and idempotency ledger as the original Notes integration.
public struct NotesMCP: MCPModule {
    public let id = "notes"
    public let title = "Apple Notes"
    public let permissionKeys: Set<String> = ["read", "create", "append"]
    private let execute: @Sendable (Data) async throws -> Data

    public init(execute: @escaping @Sendable (Data) async throws -> Data) { self.execute = execute }

    public init(python: URL, script: URL, profileHome: URL) {
        execute = { input in
            try await Task.detached {
                let process = Process(), stdin = Pipe(), stdout = Pipe()
                process.executableURL = python
                process.arguments = ["-B", script.path, profileHome.path]
                process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "pl_PL.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                try process.run()
                defer {
                    if process.isRunning {
                        if getpgid(process.processIdentifier) == process.processIdentifier { kill(-process.processIdentifier, SIGKILL) }
                        else { process.terminate() }
                        process.waitUntilExit()
                    }
                    try? stdin.fileHandleForWriting.close()
                    try? stdout.fileHandleForReading.close()
                }
                // Worker creates a private process group, including its AppleScript child.
                let timeout = DispatchWorkItem {
                    if process.isRunning {
                        if getpgid(process.processIdentifier) == process.processIdentifier {
                            kill(-process.processIdentifier, SIGKILL)
                        } else { process.terminate() }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 50, execute: timeout)
                defer { timeout.cancel() }
                do {
                    try stdin.fileHandleForWriting.write(contentsOf: input)
                    try stdin.fileHandleForWriting.close()
                } catch {
                    try? stdin.fileHandleForWriting.close()
                    process.terminate()
                    process.waitUntilExit()
                    throw IndexaError("notes_worker_failed")
                }
                var output = Data()
                while let chunk = try stdout.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    output.append(chunk)
                    if output.count > 524288 {
                        if getpgid(process.processIdentifier) == process.processIdentifier { kill(-process.processIdentifier, SIGKILL) }
                        else { process.terminate() }
                        process.waitUntilExit()
                        throw IndexaError("notes_response_too_large")
                    }
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw IndexaError("notes_worker_failed_check_before_retry") }
                return output
            }.value
        }
    }

    public func tools() async throws -> [MCPTool] {
        let text: MCPValue = .object(["type": .string("string"), "maxLength": .number(16384)])
        func schema(_ properties: [String: MCPValue], required: [String]) -> MCPValue {
            .object(["type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(MCPValue.string)), "additionalProperties": .bool(false)])
        }
        let writeHelp = " Only folder Indexa. A new write requires a UUID operation_id; reuse the same ID on retry. Never repeat needs_review with a new ID. verified=true confirms read-back."
        return [
            MCPTool(name: "notes_get", description: "Read an exact Apple Note by note_id in folder Indexa.",
                inputSchema: schema(["note_id": text], required: ["note_id"]), requiredPermissions: ["read"]),
            MCPTool(name: "notes_create", description: "Create an Apple Note." + writeHelp,
                inputSchema: schema(["title": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(200)]), "text": text, "operation_id": text], required: ["title", "text", "operation_id"]), requiredPermissions: ["create"]),
            MCPTool(name: "notes_append", description: "Append text to an exact Apple Note by note_id." + writeHelp,
                inputSchema: schema(["note_id": text, "text": text, "operation_id": text], required: ["note_id", "text", "operation_id"]), requiredPermissions: ["append"])
        ]
    }

    public func call(tool: String, arguments: MCPValue) async throws -> MCPToolResult {
        let action: String, required: Set<String>
        switch tool {
        case "notes_get": action = "read"; required = ["note_id"]
        case "notes_create": action = "create"; required = ["title", "text", "operation_id"]
        case "notes_append": action = "append"; required = ["note_id", "text", "operation_id"]
        default: throw IndexaError("unknown_notes_tool")
        }
        guard case .object(var values) = arguments, Set(values.keys) == required,
              values.values.allSatisfy({ $0.stringValue.map { !$0.isEmpty && $0.utf8.count <= 16384 } ?? false }) else {
            return .text("{\"error\":\"invalid_notes_request\"}", isError: true, diagnostic: Self.diagnostic("invalid_notes_request"))
        }
        if action != "read", UUID(uuidString: values["operation_id"]!.stringValue!) == nil {
            return .text("{\"error\":\"invalid_operation_id\"}", isError: true, diagnostic: Self.diagnostic("invalid_operation_id"))
        }
        if let note = values["note_id"]?.stringValue, !note.hasPrefix("x-coredata://") {
            return .text("{\"error\":\"invalid_note_id\"}", isError: true, diagnostic: Self.diagnostic("invalid_note_id"))
        }
        values["action"] = .string(action)
        do {
            let data = try await execute(JSONEncoder().encode(MCPValue.object(values)))
            let result = try JSONDecoder().decode(MCPValue.self, from: data)
            guard case .object = result else { throw IndexaError("invalid_notes_response") }
            return .text(String(decoding: data, as: UTF8.self), isError: result["error"] != nil,
                         diagnostic: result["error"] != nil ? Self.diagnostic(result["error"]?.stringValue ?? "") : nil)
        } catch {
            return .text("{\"error\":\"notes_unavailable_check_before_retry\",\"needs_review\":true}", isError: true, diagnostic: Self.diagnostic("notes_unavailable"))
        }
    }

    private static func diagnostic(_ code: String) -> String {
        // Only fixed descriptions reach the UI/audit; tool output may contain private note text.
        switch code {
        case "invalid_notes_request", "invalid_operation_id", "invalid_note_id":
            return "Hermes przekazał nieprawidłowe dane. Poproś go o poprawienie żądania."
        case "notes_automation_failed":
            return "Nie udało się wykonać operacji w Notatkach. Sprawdź dostęp do Notatek w ustawieniach Automatyzacji macOS."
        case "notes_readback_failed", "notes_timeout_do_not_repeat", "operation_unknown_do_not_repeat", "previous_write_needs_review", "concurrent_or_uncertain_operation":
            return "Zapis wymaga sprawdzenia. Sprawdź notatkę, a następnie otwórz Przegląd w Indexie."
        case "operation_id_conflict": return "Hermes użył identyfikatora poprzedniej operacji do innej zmiany."
        case "permission_denied": return "Brak uprawnienia do tej operacji. Sprawdź dostęp poniżej."
        case "note_too_large": return "Notatka jest zbyt duża, aby ją odczytać."
        default: return "Nie udało się wykonać operacji. Przed ponowieniem zapisu sprawdź notatkę."
        }
    }
}
