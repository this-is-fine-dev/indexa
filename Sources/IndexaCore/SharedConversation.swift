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
}
