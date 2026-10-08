import Foundation
import CryptoKit

public enum PebbleAuthentication {
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        // Hash first: bounded, equal-size comparison even for a malicious header.
        let x = Array(SHA256.hash(data: Data(a.utf8)))
        let y = Array(SHA256.hash(data: Data(b.utf8)))
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    public static func verify(body: Data, headers: [String:String], secret: String, signed: Bool,
                              now: TimeInterval = Date().timeIntervalSince1970) throws {
        guard !secret.isEmpty else { throw IndexaError("secret_unavailable") }
        if !signed {
            guard constantTimeEqual(headers["authorization"] ?? "", "Bearer \(secret)") else { throw IndexaError("unauthorized") }
            return
        }
        guard headers["x-index-webhook-version"] == "1",
              let timestamp = headers["x-index-timestamp"], !timestamp.isEmpty,
              timestamp.utf8.allSatisfy({ (48...57).contains($0) }),
              let time = TimeInterval(timestamp), time.isFinite, abs(now - time) <= 300,
              let delivery = headers["x-index-delivery"], (1...128).contains(delivery.utf8.count),
              delivery.utf8.allSatisfy({ (33...126).contains($0) }),
              let trigger = headers["x-index-trigger"], ["single-click-hold","double-click-hold","test-event"].contains(trigger),
              headers["x-index-test"] == nil || headers["x-index-test"] == "true" else { throw IndexaError("invalid_signature_headers") }
        let isTest = headers["x-index-test"] == "true"
        guard isTest == (trigger == "test-event") else { throw IndexaError("inconsistent_test") }
        let prefix = Data("v1\n\(timestamp)\n\(delivery)\n\(trigger)\n\(isTest ? "1" : "0")\n".utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: prefix + body, using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        guard constantTimeEqual(signature, headers["x-index-signature"] ?? "") else { throw IndexaError("invalid_signature") }
    }
}
