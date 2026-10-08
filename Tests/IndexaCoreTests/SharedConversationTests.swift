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
    func page(_ offset: Int, limit: Int = 200) throws -> Data {
        struct Envelope: Encodable { let data: [ChatMessage] }
        let count = max(0, messages.count - offset)
        return try JSONEncoder().encode(Envelope(data: Array(messages.prefix(count).suffix(limit))))
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
            return try await Response(status: .ok, body: .init(data: fixture.page(offset, limit: request.query[Int.self, at: "limit"] ?? 200)))
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

    @Test func streamingResponseLimitStopsBeforeUnknownLengthBodyFinishes() async throws {
        actor Probe { var finished = false; func finish() { finished = true } }
        let probe = Probe()
        let server = try await Application.make(.testing)
        server.logger.logLevel = .critical
        server.get("oversized") { _ in
            Response(status: .ok, body: .init(asyncStream: { writer in
                try await writer.write(.buffer(ByteBuffer(string: String(repeating: "x", count: 4096))))
                try await Task.sleep(for: .seconds(1))
                await probe.finish()
                try await writer.write(.end)
            }))
        }
        try await server.http.server.shared.start(address: .hostname("127.0.0.1", port: 0))
        let port = try #require(server.http.server.shared.localAddress?.port)
        do {
            _ = try await HTTPJSON().request(URL(string: "http://127.0.0.1:\(port)/oversized")!, maxBytes: 1024)
            Issue.record("Oversized streaming response was accepted")
        } catch let error as APIError {
            #expect(error.code == -3)
            #expect(await probe.finished == false)
        }
        await server.http.server.shared.shutdown()
        try await server.asyncShutdown()
    }

    @Test func oversizedImageHistoryShrinksPagesAndStillFindsOlderFinalAnswer() async throws {
        actor Requests {
            var values = [(Int, Int)]()
            func record(_ limit: Int, _ offset: Int) { values.append((limit, offset)) }
        }
        let requests = Requests()
        let fixture = ChatFixture()
        await fixture.append(ChatMessage(id: 2, role: "assistant", content: "Target answer", timestamp: 2))
        let image = "data:image/jpeg;base64," + String(repeating: "A", count: 1024 * 1024)
        for index in 3...14 { await fixture.append(ChatMessage(id: index, role: "user", content: image, timestamp: Double(index))) }
        await fixture.append(ChatMessage(id: 15, role: "assistant", content: "Working", timestamp: 15, finish_reason: "tool_calls"))
        let server = try await Application.make(.testing)
        server.logger.logLevel = .critical
        server.get("api", "sessions", "canonical", "messages") { request async throws -> Response in
            let offset = request.query[Int.self, at: "offset"] ?? 0
            let limit = request.query[Int.self, at: "limit"] ?? 200
            await requests.record(limit, offset)
            return try await Response(status: .ok, body: .init(data: fixture.page(offset, limit: limit)))
        }
        try await server.http.server.shared.start(address: .hostname("127.0.0.1", port: 0))
        let port = try #require(server.http.server.shared.localAddress?.port)
        do {
            let client = HermesClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, key: "synthetic")
            #expect(try await client.finalAnswerID(session: "canonical", output: "Target answer", createdAt: 1.5, completedAt: 2.5) != nil)
            let calls = await requests.values
            #expect(calls.first?.0 == 20)
            #expect(calls.contains { $0.0 == 10 && $0.1 == 0 })
            #expect(calls.contains { $0.0 == 5 && $0.1 == 0 })
            #expect(calls.contains { $0.1 == 5 })
            #expect(calls.contains { $0.1 == 10 })
        } catch {
            await server.http.server.shared.shutdown(); try await server.asyncShutdown()
            throw error
        }
        await server.http.server.shared.shutdown()
        try await server.asyncShutdown()
    }

}
