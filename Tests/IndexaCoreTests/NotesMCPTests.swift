import Foundation
import Testing
@testable import IndexaCore

struct NotesMCPTests {
    @Test func nativeProcessRunsWorkerWithValidRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let worker = directory.appendingPathComponent("mcp_notes.py")
        try FileManager.default.copyItem(at: root.appendingPathComponent("hermes-plugin/mcp_notes.py"), to: worker)
        // Exercise the real Foundation Process + worker startup without accessing Apple Notes.
        try """
        import json, os
        def handle_core(args, home, approve):
            assert os.getpgrp() == os.getpid()
            assert args['action'] == 'create' and approve(args)
            return json.dumps({'verified': True, 'note_id': 'x-coredata://synthetic'})
        """.write(to: directory.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
        let notes = NotesMCP(python: URL(fileURLWithPath: "/usr/bin/python3"), script: worker, profileHome: directory)
        let result = try await notes.call(tool: "notes_create", arguments: .object([
            "title": .string("Synthetic"), "text": .string("Text"), "operation_id": .string(UUID().uuidString)
        ]))
        #expect(!result.isError, "Valid MCP input must reach the Notes handler through the native subprocess")
    }

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
