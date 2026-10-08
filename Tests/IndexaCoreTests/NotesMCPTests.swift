import Foundation
import Testing
@testable import IndexaCore

struct NotesMCPTests {
    @Test func validatesBeforeLaunchingAndKeepsOperationID() async throws {
        actor Calls {
            var values: [MCPValue] = []
            func run(_ data: Data) throws -> Data {
                values.append(try JSONDecoder().decode(MCPValue.self, from: data))
                return Data(#"{"note_id":"x-coredata://synthetic","verified":true}"#.utf8)
            }
        }
        let calls = Calls(), notes = NotesMCP(execute: { try await calls.run($0) })
        let invalid = try await notes.call(tool: "notes_create", arguments: .object(["text": .string("ignored")]))
        #expect(invalid.isError)
        #expect(await calls.values.isEmpty)
        let id = UUID().uuidString
        let args: MCPValue = .object(["title": .string("Synthetic"), "text": .string("Text"), "operation_id": .string(id)])
        #expect(try await !notes.call(tool: "notes_create", arguments: args).isError)
        #expect(await calls.values.first?["operation_id"] == .string(id))
        #expect(await calls.values.first?["action"] == .string("create"))
        let tools = try await notes.tools()
        #expect(tools.map(\.requiredPermissions) == [Set(["read"]), Set(["create"]), Set(["append"])])
    }
}
