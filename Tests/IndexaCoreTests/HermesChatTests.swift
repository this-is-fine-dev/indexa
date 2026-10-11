import Foundation
import Testing
@testable import IndexaCore

struct HermesChatTests {
    @Test func decodesTheInputFieldSentByTheIOSClient() throws {
        let request = try JSONDecoder().decode(HermesChatPrompt.self, from: Data("{\"input\":\"sprawdź urlop\"}".utf8))
        #expect(request.input == "sprawdź urlop")
    }
}
