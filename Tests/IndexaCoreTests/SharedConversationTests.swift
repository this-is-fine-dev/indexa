import Foundation
import Testing
import Vapor
@testable import IndexaCore

private struct ChatMessage: Codable, Sendable {
    var id: Int
    let role: String
    let content: String
    let timestamp: Double
    var finish_reason: String = "stop"
}
private actor ChatFixture {
    var messages = [ChatMessage(id: 1, role: "assistant", content: "Old history", timestamp: 1)]
    func append(_ message: ChatMessage) { messages.append(message) }
    func compact() { for i in messages.indices { messages[i].id += 100 } }
    func page(_ offset: Int) throws -> Data {
        struct Envelope: Encodable { let data: [ChatMessage] }
        let count = max(0, messages.count - offset)
        return try JSONEncoder().encode(Envelope(data: Array(messages.prefix(count).suffix(200))))
    }
}

struct SharedConversationTests {
    @Test func sharesCanonicalChatAndDeliversEachFinalOnceAcrossRestartAndCompression() async throws {
        let db = try Database(url: nil), fixture = ChatFixture()
        let server = try await Application.make(.testing)
        server.logger.logLevel = .critical
        server.get("api", "sessions") { request in
            #expect(request.query[String.self, at: "title"] == "Bot Chat")
            return Response(status: .ok, body: .init(string: "{\"data\":[{\"id\":\"canonical\",\"title\":\"Bot Chat\",\"hidden\":true}]}"))
        }
        server.get("api", "sessions", "canonical", "messages") { request async throws -> Response in
            let offset = request.query[Int.self, at: "offset"] ?? 0
            return try await Response(status: .ok, body: .init(data: fixture.page(offset)))
        }
        try await server.http.server.shared.start(address: .hostname("127.0.0.1", port: 0))
        let port = try #require(server.http.server.shared.localAddress?.port)
        let client = HermesClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, key: "fixture")
        let mirror = SharedConversation(database: db, hermes: client)
        _ = try await db.ingestMatrix(id: "$incoming", text: "test", recorded: 1)
        try await mirror.tick(destination: "room")
        #expect(try await db.value("conversation") == "canonical")
        #expect(try await db.tasks().first?.session == "canonical")
        #expect(try await db.outbox().isEmpty) // Never replay pre-upgrade history.
        await fixture.append(ChatMessage(id: 2, role: "user", content: "Desktop turn", timestamp: 2))
        await fixture.append(ChatMessage(id: 3, role: "assistant", content: "Tool commentary", timestamp: 3, finish_reason: "tool_calls"))
        await fixture.append(ChatMessage(id: 4, role: "assistant", content: "Answer", timestamp: 4))
        try await mirror.tick(destination: "room")
        try await mirror.tick(destination: "room")
        #expect(try await db.outbox().map(\.body) == ["Answer"])
        await fixture.compact()
        let restarted = SharedConversation(database: db, hermes: client)
        try await restarted.tick(destination: "room")
        #expect(try await db.outbox().count == 1)
        await fixture.append(ChatMessage(id: 105, role: "assistant", content: "Answer", timestamp: 5))
        try await restarted.tick(destination: "room")
        #expect(try await db.outbox().count == 2) // Identical text from another turn is legitimate.
        let delivered = try #require(try await client.finalAnswerID(session: "canonical", output: "Answer", createdAt: 4.5, completedAt: 5.5))
        let task = try #require(try await db.tasks().first)
        try await db.finish(task.id, state: "completed", result: "Answer", destination: "room", deliveryEvent: delivered)
        #expect(try await db.outbox().count == 2) // Worker completion and mirror use one delivery identity.

        // A run finishing before the FIRST upgraded poll must still be delivered by the worker.
        let upgradeDB = try Database(url: nil)
        let accepted = try await upgradeDB.ingestMatrix(id: "$pre-upgrade", text: "existing run", recorded: 4.5)
        let upgrade = SharedConversation(database: upgradeDB, hermes: client)
        try await upgrade.tick(destination: "room")
        #expect(try await upgradeDB.outbox().isEmpty)
        try await upgradeDB.finish(accepted.id, state: "completed", result: "Answer", destination: "room", deliveryEvent: delivered)
        try await upgrade.tick(destination: "room")
        #expect(try await upgradeDB.outbox().count == 1)
        #expect(try await client.finalAnswerID(session: "canonical", output: "API-only answer", createdAt: 5, completedAt: 6) == nil)
        await server.http.server.shared.shutdown()
        try await server.asyncShutdown()
    }
}
