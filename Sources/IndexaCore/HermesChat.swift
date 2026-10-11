import Foundation
import Vapor

public struct HermesChatMessage: Encodable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let timestamp: Double
}

struct HermesChatPrompt: Codable {
    let input: String
}

/// Narrow iPhone bridge: the phone receives neither Hermes' API key nor its general API.
public struct HermesChatRelay: Sendable {
    private let hermes: HermesClient

    public init(hermes: HermesClient) { self.hermes = hermes }

    public func history() async throws -> [HermesChatMessage] {
        let session = try await hermes.canonicalConversation()
        let messages = try await hermes.conversationMessages(session)
        return try messages.messages.reversed().compactMap { message in
            guard let role = message["role"] as? String,
                  let timestamp = (message["timestamp"] as? NSNumber)?.doubleValue else { return nil }
            if role == "user", let text = message["content"] as? String, !text.isEmpty {
                let identity = try JSONSerialization.data(withJSONObject: ["time": timestamp, "content": text], options: .sortedKeys)
                return HermesChatMessage(id: PebbleAuthentication.digest(identity), role: role, text: text, timestamp: timestamp)
            }
            if role == "assistant", let answer = try HermesClient.visibleAnswer(message) {
                return HermesChatMessage(id: answer.id, role: role, text: answer.text, timestamp: timestamp)
            }
            return nil
        }
    }

    public func stream(_ text: String, to writer: AsyncBodyStreamWriter) async throws {
        do {
            let session = try await hermes.canonicalConversation()
            var request = URLRequest(url: hermes.baseURL.appendingPathComponent("api/sessions/\(session)/chat/stream"))
            request.httpMethod = "POST"
            request.timeoutInterval = 60 * 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(hermes.key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(HermesChatPrompt(input: text))
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                try await writeError("hermes_request_failed", to: writer)
                return
            }
            var buffer = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.suffix(2).elementsEqual([10, 10]) || buffer.suffix(4).elementsEqual([13, 10, 13, 10]) || buffer.count >= 8192 {
                    try await writer.write(.buffer(ByteBuffer(data: buffer)))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { try await writer.write(.buffer(ByteBuffer(data: buffer))) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await writeError("hermes_unavailable", to: writer)
        }
    }

    private func writeError(_ code: String, to writer: AsyncBodyStreamWriter) async throws {
        let frame = "event: error\ndata: {\"error\":\"\(code)\"}\n\n"
        try await writer.write(.buffer(ByteBuffer(string: frame)))
    }
}
