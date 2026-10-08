import Foundation

extension HermesClient {
    /// Hermes identifies a bot's permanent chat by its exact title, not a cached session ID.
    public func canonicalConversation() async throws -> String {
        func lookup() async throws -> String? {
            var url = URLComponents(url: baseURL.appendingPathComponent("api/sessions"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "title", value: "Bot Chat"), URLQueryItem(name: "include_hidden", value: "1")]
            let result = try await http.request(url.url!, headers: ["Authorization": "Bearer \(key)"])
            guard let sessions = result["data"] as? [[String: Any]] else { throw IndexaError("invalid_hermes_sessions") }
            let matches = sessions.filter { ($0["title"] as? String) == "Bot Chat" && ($0["archived"] as? Bool) != true }
            guard matches.count <= 1 else { throw IndexaError("ambiguous_bot_chat") }
            guard let match = matches.first else { return nil }
            guard let id = match["id"] as? String, Self.validSessionID(id) else { throw IndexaError("invalid_hermes_session") }
            return id
        }
        if let id = try await lookup() { return id }
        let id = "indexa-" + UUID().uuidString
        do {
            _ = try await http.request(baseURL.appendingPathComponent("api/sessions"), method: "POST",
                body: JSONSerialization.data(withJSONObject: ["id": id, "source": "api_server", "title": "Bot Chat"]),
                headers: ["Authorization": "Bearer \(key)"])
        } catch {
            // Desktop may win the title claim, or the successful create response may be lost.
            if let existing = try await lookup() { return existing }
            throw error
        }
        _ = try await http.request(baseURL.appendingPathComponent("api/sessions/\(id)"), method: "PATCH",
            body: Data("{\"hidden\":true}".utf8), headers: ["Authorization": "Bearer \(key)"])
        return id
    }

    private static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    func conversationMessages(_ session: String, offset: Int = 0) async throws -> (messages:[[String: Any]],limit:Int) {
        guard Self.validSessionID(session) else { throw IndexaError("invalid_hermes_session") }
        var limit=20
        while true {
            var url = URLComponents(url: baseURL.appendingPathComponent("api/sessions/\(session)/messages"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset)),
                             URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "include_compacted", value: "1")]
            do {
                // One 5 MiB image fits; reduce page size when several images exceed the budget.
                let result = try await http.request(url.url!, headers: ["Authorization": "Bearer \(key)"],maxBytes:8*1024*1024)
                guard let messages = result["data"] as? [[String: Any]] else { throw IndexaError("invalid_hermes_messages") }
                return (messages,limit)
            } catch let error as APIError where error.code == -3 && limit > 1 { limit=max(1,limit/2) }
        }
    }

    public func finalAnswerID(session: String, output: String, createdAt: Double?, completedAt: Double?) async throws -> String? {
        guard let createdAt, let completedAt else { throw IndexaError("run_delivery_timestamps_missing") }
        // Bind delivery to a persisted message within this run, never an old equal-text outbox item.
        var offset=0
        while offset < 4000 {
            let page = try await conversationMessages(session, offset: offset)
            let messages=page.messages;offset += messages.count
            for message in messages.reversed() {
                guard let time = (message["timestamp"] as? NSNumber)?.doubleValue,
                      time >= createdAt, time <= completedAt,
                      let answer = try Self.visibleAnswer(message), answer.text == output else { continue }
                return "hermes-message:" + answer.id
            }
            if messages.count < page.limit { return nil }
            if messages.allSatisfy({ (($0["timestamp"] as? NSNumber)?.doubleValue ?? completedAt) < createdAt }) { return nil }
        }
        throw IndexaError("shared_chat_history_gap")
    }

    static func visibleAnswer(_ message: [String: Any]) throws -> (id: String, text: String)? {
        guard message["role"] as? String == "assistant", message["finish_reason"] as? String == "stop",
              (message["tool_calls"] as? [Any])?.isEmpty != false,
              let text = message["content"] as? String, !text.isEmpty else { return nil }
        guard let timestamp = message["timestamp"] as? NSNumber else { throw IndexaError("invalid_hermes_message_identity") }
        // Hermes preserves logical timestamps while copying rows during compression.
        let identity = try JSONSerialization.data(withJSONObject: ["time": timestamp, "content": text], options: .sortedKeys)
        return (PebbleAuthentication.digest(identity), text)
    }
}

/// One delivery path for final answers, whether a turn started on the Mac, Matrix or Pebble.
public actor SharedConversation {
    private let db: Database
    private let hermes: HermesClient
    private var busy = false
    public init(database: Database, hermes: HermesClient) { db = database; self.hermes = hermes }

    public func tick(destination: String) async throws {
        guard !busy, !destination.isEmpty else { return }
        busy = true; defer { busy = false }
        let session = try await hermes.canonicalConversation()
        try await db.bindConversation(session)
        let cursorKey = "shared-answer-cursor"
        let previous = try await db.value(cursorKey)
        var answers = [(id: String, text: String)]()
        var reachedCursor = false
        // ponytail: cap recovery at 4,000 messages; larger gaps stop visibly instead of dropping history.
        var offset=0
        while offset < 4000 {
            let page = try await hermes.conversationMessages(session, offset: offset)
            let messages=page.messages;offset += messages.count
            let finals = try messages.compactMap(HermesClient.visibleAnswer)
            if previous == nil {
                if let last = finals.last { try await db.setValue(cursorKey, last.id); return }
                if messages.count < page.limit { try await db.setValue(cursorKey, ""); return }
                continue
            }
            if let index = finals.lastIndex(where: { $0.id == previous }) {
                answers = Array(finals.suffix(from: index + 1)) + answers
                reachedCursor = true
                break
            }
            answers = finals + answers
            if messages.count < page.limit { reachedCursor = previous == ""; break }
        }
        guard previous != nil, reachedCursor else { throw IndexaError("shared_chat_history_gap") }
        for answer in answers {
            try await db.enqueue(event: "hermes-message:" + answer.id, kind: "shared-answer", destination: destination, body: answer.text)
        }
        if let last = answers.last { try await db.setValue(cursorKey, last.id) }
    }
}
