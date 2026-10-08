import Combine
import Testing
import IndexaCore
@testable import IndexaApp

struct RuntimeRefreshTests {
    @Test @MainActor func unchangedMCPPollDoesNotInvalidateUI() async throws {
        let runtime = Runtime()
        let manager = try MCPManager(token: String(repeating: "t", count: 48), modules: [FilesMCP()])
        runtime.mcpManager = manager
        await runtime.refreshMCP()
        var updates = 0
        let observation = runtime.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }

        for _ in 0..<5 { await runtime.refreshMCP() }
        #expect(updates == 0, "Idle polling must not redraw every integration and the whole window")
        try await manager.setEnabled(true, for: "files")
        await runtime.refreshMCP()
        #expect(updates == 1)
        #expect(runtime.mcpModules.first?.enabled == true)
        await runtime.refreshMCP()
        #expect(updates == 1)
    }
}
