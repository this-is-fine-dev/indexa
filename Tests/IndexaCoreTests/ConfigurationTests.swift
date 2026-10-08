import Testing
import Foundation
@testable import IndexaCore

struct ConfigurationTests {
    @Test func rejectsRemoteHermesAndInvalidRetention() throws {
        var config = Configuration()
        try config.validate()
        config.hermesURL = "http://example.com:18762"
        #expect(throws: (any Error).self) { try config.validate() }
        config.hermesURL = "http://127.0.0.1:18762"
        config.metadataRetentionDays = 1
        #expect(throws: (any Error).self) { try config.validate() }
    }

    @Test func roundTripContainsNoCredentials() throws {
        let config = Configuration()
        let bytes = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(Configuration.self, from: bytes) == config)
        #expect(!String(decoding: bytes, as: UTF8.self).lowercased().contains("token"))
    }
}
