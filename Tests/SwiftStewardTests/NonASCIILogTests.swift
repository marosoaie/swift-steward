import Foundation
import Testing
@testable import BuildLogKit

/// Non-ASCII input through the Regex-based line parsers and the JSON
/// decoder, where the platforms' Unicode handling could diverge.
@Suite("Non-ASCII log input")
struct NonASCIILogTests {
    @Test("non-ASCII paths, messages, and rules come through each tool parser intact")
    func toolParsers() {
        #expect(XcodeLogParser.diagnostics(in: """
            /ci/Sources/Café/日本語 View.swift:12:5: warning: “naïve” is never used 🚧 [-Wunused-variable]
            """) == [
                Diagnostic(
                    path: "/ci/Sources/Café/日本語 View.swift", line: 12, column: 5,
                    severity: .warning, message: "“naïve” is never used 🚧", rule: "-Wunused-variable"
                ),
            ])
        #expect(SwiftLintLogParser.diagnostics(in: """
            /ci/Sources/Ünïcode/Fïle.swift:3:1: warning: Identifier Name Violation: ‘ç’ is too short (identifier_name)
            """) == [
                Diagnostic(
                    path: "/ci/Sources/Ünïcode/Fïle.swift", line: 3, column: 1,
                    severity: .warning, message: "Identifier Name Violation: ‘ç’ is too short",
                    rule: "identifier_name"
                ),
            ])
        #expect(SwiftFormatLogParser.diagnostics(in: """
            /ci/Sources/Ωmega.swift:7:1: error: (redundantSelf) Remove explicit self — “self.x”.
            """) == [
                Diagnostic(
                    path: "/ci/Sources/Ωmega.swift", line: 7, column: 1,
                    severity: .error, message: "Remove explicit self — “self.x”.", rule: "redundantSelf"
                ),
            ])
    }

    @Test("decomposed accents keep their bytes rather than being normalized")
    func decomposedAccents() throws {
        let decomposed = "/ci/Cafe\u{301}.swift"
        let diagnostic = try #require(ClangStyleLogParser.diagnostics(in: """
            \(decomposed):1:1: warning: x
            """).first)
        // String == compares canonical equivalence, so compare the bytes.
        #expect(Array(diagnostic.path.utf8) == Array(decomposed.utf8))
    }

    @Test(
        "line numbers in non-ASCII digits are not diagnostics",
        arguments: ["/ci/a.swift:١٢:3: warning: Arabic-Indic", "/ci/a.swift:１２:3: warning: fullwidth"]
    )
    func nonASCIIDigits(line: String) {
        // Regex's \d matches every Unicode decimal digit, but Int(_:) only
        // parses ASCII ones, so these lines are dropped rather than trapping.
        #expect(ClangStyleLogParser.diagnostics(in: line).isEmpty)
    }

    @Test("invalid UTF-8 is replaced and the rest of the line still parses")
    func invalidUTF8() {
        var parser = ClangStyleLogParser()
        parser.consume(Array("/ci/a.swift:3:1: warning: bad ".utf8) + [0xFF] + Array(" byte\n".utf8))
        parser.consume(Array("/ci/b".utf8) + [0xC3] + Array(".swift:4:2: error: truncated sequence\n".utf8))
        #expect(parser.finalize() == [
            Diagnostic(path: "/ci/a.swift", line: 3, column: 1, severity: .warning, message: "bad \u{FFFD} byte"),
            Diagnostic(
                path: "/ci/b\u{FFFD}.swift", line: 4, column: 2, severity: .error, message: "truncated sequence"
            ),
        ])
    }

    @Test("SonarQube messages decode the same from JSON escapes and from raw UTF-8")
    func sonarEscapes() {
        func message(_ json: String) -> String? {
            SonarReportParser.diagnostics(in: """
                [{"component": "p:a.swift", "line": 1, "severity": "MAJOR", "message": "\(json)"}]
                """).first?.message
        }
        let raw = "Café 🚧 日本語 “quoted”"
        #expect(message(raw) == raw)
        #expect(message(#"Café 🚧 日本語 “quoted”"#) == raw)
        #expect(message(#"tab\tnewline\nslash\/quote\""#) == "tab\tnewline\nslash/quote\"")
    }

    @Test("a SonarQube report with an unpaired surrogate escape yields no diagnostics")
    func sonarLoneSurrogate() {
        // Not valid Unicode, so the decoder rejects the whole document; the
        // parser degrades to no diagnostics, like any other malformed report.
        #expect(SonarReportParser.diagnostics(in: #"""
            [{"component": "p:a.swift", "line": 1, "severity": "MAJOR", "message": "\ud83d alone"}]
            """#).isEmpty)
    }
}
