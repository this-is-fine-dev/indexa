import Foundation
import Testing
import CryptoKit
@testable import IndexaCore

struct SignatureTests {
    @Test func authenticatesRawBodyAndSignedFields() throws {
        let body = Data("synthetic multipart bytes: żółć".utf8)
        var headers = ["x-index-webhook-version":"1", "x-index-timestamp":"1000", "x-index-delivery":"fixture-1", "x-index-trigger":"double-click-hold"]
        let key = "synthetic-secret-not-a-real-credential"
        let prefix = Data("v1\n1000\nfixture-1\ndouble-click-hold\n0\n".utf8)
        headers["x-index-signature"] = HMAC<SHA256>.authenticationCode(for: prefix + body, using: SymmetricKey(data: Data(key.utf8))).map { String(format:"%02x",$0) }.joined()
        try PebbleAuthentication.verify(body: body, headers: headers, secret: key, signed: true, now: 1000)
        #expect(throws: (any Error).self) { try PebbleAuthentication.verify(body: body + Data([0]), headers: headers, secret: key, signed: true, now: 1000) }
        #expect(throws: (any Error).self) { try PebbleAuthentication.verify(body: body, headers: headers, secret: key, signed: true, now: 1400) }
        headers["x-index-test"] = "true"
        #expect(throws: (any Error).self) { try PebbleAuthentication.verify(body: body, headers: headers, secret: key, signed: true, now: 1000) }
        headers["authorization"] = "Bearer \(key)"
        #expect(throws: (any Error).self) { try PebbleAuthentication.verify(body: body, headers: headers, secret: key, signed: true, now: 1000) }
    }
    @Test func legacyModeRequiresExplicitToken() throws {
        #expect(throws: (any Error).self) { try PebbleAuthentication.verify(body: Data(), headers: [:], secret: "abc", signed: false) }
        try PebbleAuthentication.verify(body: Data(), headers: ["authorization":"Bearer abc"], secret: "abc", signed: false)
    }
    @Test func authenticatesIOSChatRoutesWithTheirOwnTriggers() throws {
        let body = Data("{\"input\":\"sprawdź urlop\"}".utf8)
        let key = "synthetic-chat-secret"
        for trigger in ["ios-chat", "ios-history"] {
            var headers = ["x-index-webhook-version":"1", "x-index-timestamp":"1000",
                           "x-index-delivery":"fixture-\(trigger)", "x-index-trigger":trigger]
            let prefix = Data("v1\n1000\nfixture-\(trigger)\n\(trigger)\n0\n".utf8)
            headers["x-index-signature"] = HMAC<SHA256>.authenticationCode(
                for: prefix + body, using: SymmetricKey(data: Data(key.utf8))
            ).map { String(format:"%02x", $0) }.joined()
            try PebbleAuthentication.verify(body: body, headers: headers, secret: key, signed: true, now: 1000)
        }
    }
}
