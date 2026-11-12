import Testing
@testable import BuildLogKit

@Suite("Tool-specific log parsers")
struct ToolLogParserTests {
    @Test("XcodeLogParser extracts clang warning flags and passes swiftc lines through")
    func xcodeParser() {
        let log = """
        Build settings from command line:
        /repo/src/main.c:7:9: warning: unused variable 'x' [-Wunused-variable]
        /repo/Sources/App/Foo.swift:42:13: warning: initialization of immutable value 'y' was never used
        """
        #expect(XcodeLogParser.diagnostics(in: log) == [
            Diagnostic(
                path: "/repo/src/main.c", line: 7, column: 9,
                severity: .warning, message: "unused variable 'x'",
                rule: "-Wunused-variable"
            ),
            Diagnostic(
                path: "/repo/Sources/App/Foo.swift", line: 42, column: 13,
                severity: .warning,
                message: "initialization of immutable value 'y' was never used"
            ),
        ])
    }

    @Test("XcodeLogParser handles -Werror flag lists and unusual flag characters")
    func xcodeParserFlagVariants() {
        // All three message shapes verified against Apple clang 17 output.
        let log = """
        /repo/src/a.c:1:22: error: unused variable 'x' [-Werror,-Wunused-variable]
        /repo/src/b.c:1:2: warning: "hand-rolled warning" [-W#warnings]
        /repo/src/c.c:1:9: warning: check this [-W#pragma-messages]
        """
        #expect(XcodeLogParser.diagnostics(in: log).map(\.rule) == [
            "-Wunused-variable",
            "-W#warnings",
            "-W#pragma-messages",
        ])
        #expect(XcodeLogParser.diagnostics(in: log)[0].message == "unused variable 'x'")
    }

    @Test("SwiftLintLogParser extracts the trailing rule identifier")
    func swiftLintParser() {
        // Verbatim SwiftLint output; the fixture lines stay un-wrapped.
        // swiftlint:disable line_length
        let log = """
        Linting Swift files in current working directory
        Linting 'Foo.swift' (1/2)
        /repo/Sources/App/Foo.swift:10:5: warning: Line Length Violation: Line should be 120 characters or less: currently 131 characters (line_length)
        /repo/Sources/App/Foo.swift:20:1: error: Force Cast Violation: Force casts should be avoided (force_cast)
        Done linting! Found 2 violations, 1 serious in 2 files.
        """
        // swiftlint:enable line_length
        #expect(SwiftLintLogParser.diagnostics(in: log) == [
            Diagnostic(
                path: "/repo/Sources/App/Foo.swift", line: 10, column: 5,
                severity: .warning,
                message: "Line Length Violation: Line should be 120 characters or less: currently 131 characters",
                rule: "line_length"
            ),
            Diagnostic(
                path: "/repo/Sources/App/Foo.swift", line: 20, column: 1,
                severity: .error,
                message: "Force Cast Violation: Force casts should be avoided",
                rule: "force_cast"
            ),
        ])
    }

    @Test("SwiftLintLogParser handles camelCase and kebab-case custom rule ids")
    func swiftLintCustomRules() {
        let log = """
        /repo/A.swift:2:5: warning: Custom Rule Violation: avoid prints (NoPrint)
        /repo/A.swift:9:1: warning: Custom Rule Violation: no magic numbers (no-magic)
        """
        #expect(SwiftLintLogParser.diagnostics(in: log).map(\.rule) == ["NoPrint", "no-magic"])
    }

    @Test("SwiftFormatLogParser extracts the leading rule name")
    func swiftFormatParser() {
        let log = """
        Running SwiftFormat...
        /repo/Sources/App/Foo.swift:12:1: warning: (indent) Indent code in accordance with the scope level.
        /repo/Sources/App/Bar.swift:3:1: warning: (redundantSelf) Insert explicit .self where required.
        SwiftFormat completed in 0.45s
        """
        #expect(SwiftFormatLogParser.diagnostics(in: log) == [
            Diagnostic(
                path: "/repo/Sources/App/Foo.swift", line: 12, column: 1,
                severity: .warning,
                message: "Indent code in accordance with the scope level.",
                rule: "indent"
            ),
            Diagnostic(
                path: "/repo/Sources/App/Bar.swift", line: 3, column: 1,
                severity: .warning,
                message: "Insert explicit .self where required.",
                rule: "redundantSelf"
            ),
        ])
    }

    @Test("a trailing rule is found after brackets or parentheses earlier in the message, with its whitespace")
    func trailingRuleAfterOtherGroups() {
        let log = """
        /repo/a.c:1:1: warning: array 'a[1]' is past the end\t [-Warray-bounds]
        /repo/a.c:2:1: warning: not a flag [x]
        /repo/A.swift:3:1: warning: call f(x) here (my_rule)
        /repo/A.swift:4:1: warning: two (a) (b c)
        """
        let xcode = XcodeLogParser.diagnostics(in: log)
        #expect(xcode.map(\.message).prefix(2) == ["array 'a[1]' is past the end", "not a flag [x]"])
        #expect(xcode.map(\.rule).prefix(2) == ["-Warray-bounds", nil])
        let swiftLint = SwiftLintLogParser.diagnostics(in: log)
        #expect(swiftLint.map(\.message).suffix(2) == ["call f(x) here", "two (a) (b c)"])
        #expect(swiftLint.map(\.rule).suffix(2) == ["my_rule", nil])
    }

    /// Long enough that matching from every character of the run, as a
    /// regex with a leading `\s*` did, takes far longer than the limit.
    @Test(
        "a long run of spaces or of openings in a message is read in linear time",
        .timeLimit(.minutes(1)),
        arguments: [(" ", 1 << 18), ("[-W", 1 << 16), ("(a ", 1 << 16)]
    )
    func longRuns(unit: String, count: Int) {
        let run = "x" + String(repeating: unit, count: count)
        let kept = String(run.reversed().drop { $0.isWhitespace }.reversed())
        let xcode = XcodeLogParser.diagnostics(in: """
            /repo/a.c:1:1: warning: \(run)y
            /repo/a.c:2:1: warning: \(run) [-Wflag]
            """)
        #expect(xcode.map(\.message) == [run + "y", kept])
        #expect(xcode.map(\.rule) == [nil, "-Wflag"])
        let swiftLint = SwiftLintLogParser.diagnostics(in: """
            /repo/A.swift:1:1: warning: \(run)y
            /repo/A.swift:2:1: warning: \(run) (rule)
            """)
        #expect(swiftLint.map(\.message) == [run + "y", kept])
        #expect(swiftLint.map(\.rule) == [nil, "rule"])
    }

    @Test("the generic parser leaves rules embedded in the message")
    func genericParserKeepsMessagesVerbatim() {
        let line = "/repo/A.swift:1:1: warning: Something (some_rule)"
        let parsed = ClangStyleLogParser.diagnostics(in: line)
        #expect(parsed.count == 1)
        #expect(parsed[0].message == "Something (some_rule)")
        #expect(parsed[0].rule == nil)
    }

    @Test("tool parsers deduplicate after rule extraction")
    func dedupAfterRefinement() {
        // Same diagnostic printed by two xcodebuild targets.
        let log = """
        /repo/a.c:1:1: warning: unused variable 'x' [-Wunused-variable]
        /repo/a.c:1:1: warning: unused variable 'x' [-Wunused-variable]
        """
        #expect(XcodeLogParser.diagnostics(in: log).count == 1)
    }

    @Test("tool parsers stream chunk-size independently", arguments: [1, 7, 4096])
    func chunkedEquivalence(chunkSize: Int) {
        let log = """
        noise line
        /repo/Sources/App/Foo.swift:10:5: warning: Line too long (line_length)
        """
        let bytes = Array(log.utf8)
        var parser = SwiftLintLogParser()
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            parser.consume(bytes[index..<end])
            index = end
        }
        #expect(parser.finalize() == SwiftLintLogParser.diagnostics(in: log))
    }
}
