@testable import ExactMacConsole
import Foundation
import Testing

/// The channel's token comparison, which is the whole authentication on the console side.
@Suite("Console channel token")
struct ConsoleTokenTests {
    @Test
    func `an exact match passes, and hex is case-insensitive`() {
        let token = String(repeating: "a1b2", count: 16)
        #expect(ConsoleToken.matches(token, token))
        #expect(ConsoleToken.matches(token, token.uppercased()))
    }

    @Test
    func `a near miss is a miss`() {
        let token = String(repeating: "a", count: 64)
        #expect(!ConsoleToken.matches(token, String(token.dropLast()) + "0"))
        #expect(!ConsoleToken.matches(token, String(repeating: "a", count: 63)))
        #expect(!ConsoleToken.matches(token, ""))
        #expect(!ConsoleToken.matches(token, token + "a"))
    }

    @Test
    func `an empty expected token never authenticates`() {
        #expect(!ConsoleToken.matches("", ""))
        #expect(!ConsoleToken.matches("", String(repeating: "a", count: 64)))
    }
}
