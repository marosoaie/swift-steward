import Foundation
@testable import Steward
import Testing

@Suite("Findings")
struct FindingTests {
    @Test("the factories make findings of their kind, with or without a location, and no rule")
    func factories() {
        let location = Location(path: "Sources/App.swift", line: 12)
        #expect(Finding.failure("f") == Finding(kind: .failure, text: "f"))
        #expect(Finding.warning("w", at: location) == Finding(kind: .warning, text: "w", location: location))
        #expect(Finding.message("m", at: Location(path: "README.md")).location?.line == nil)
        #expect(Finding.markdown("| a |") == Finding(kind: .markdown, text: "| a |"))
        #expect([Finding.failure("f"), .warning("w"), .message("m"), .markdown("d")].allSatisfy { $0.rule == nil })
    }

    @Test("a finding encodes to the report's keys, without the ones it lacks")
    func keys() throws {
        let located = Finding(kind: .warning, text: "w", location: Location(path: "a.swift", line: 3), rule: "R")
        #expect(try Self.json(located) == """
            {"kind":"warning","location":{"line":3,"path":"a.swift"},"rule":"R","text":"w"}
            """)
        #expect(try Self.json(Finding.message("m")) == #"{"kind":"message","text":"m"}"#)
        #expect(try Self.json(Finding.failure("f", at: Location(path: "a"))) == """
            {"kind":"failure","location":{"path":"a"},"text":"f"}
            """)
    }

    @Test("every kind survives a round trip through JSON", arguments: [
        Finding.Kind.failure, .warning, .message, .markdown,
    ])
    func roundTrip(kind: Finding.Kind) throws {
        let finding = Finding(kind: kind, text: "t\n|x|", location: Location(path: "p", line: 1), rule: "R")
        #expect(try JSONDecoder().decode(Finding.self, from: JSONEncoder().encode(finding)) == finding)
    }

    @Test("an unknown kind fails to decode rather than being guessed")
    func unknownKind() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Finding.self, from: Data(#"{"kind":"suggestion","text":"t"}"#.utf8))
        }
    }

    private static func json(_ finding: Finding) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(finding), as: UTF8.self)
    }
}
