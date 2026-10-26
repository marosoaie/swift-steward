import BuildLogKit
import DiffDiagnostics
import GitDiffKit
@testable import Steward
import Testing

/// The mapping from the built commit to the head, on its own.
@Suite("Matching diagnostics through a line map")
struct DiagnosticsLineMapTests {
    /// The base inserted two lines at the top of `a.swift` and renamed
    /// `old.swift` to `new.swift`, inserting a line at its top.
    private static let lineMap: LineMap = {
        var parser = DiffEventParser(consumer: LineMap.Collector())
        parser.consume("""
            diff --git a/a.swift b/a.swift
            index 1111111..2222222 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -0,0 +1,2 @@
            +base
            +base
            diff --git a/old.swift b/new.swift
            similarity index 90%
            rename from old.swift
            rename to new.swift
            index 3333333..4444444 100644
            --- a/old.swift
            +++ b/new.swift
            @@ -0,0 +1 @@
            +base

            """)
        return parser.finalize().map
    }()

    private static let changes = ChangedLines(files: [
        "a.swift": LineRangeSet([3...3]),
        "old.swift": LineRangeSet([5...5]),
    ])

    private func diagnostic(_ path: String, _ line: Int, _ message: String = "m") -> Diagnostic {
        Diagnostic(path: path, line: line, column: nil, severity: .warning, message: message)
    }

    @Test("built lines map to head lines, through the base's rename too, and lines the base wrote are dropped")
    func mapped() {
        let (matched, dropped) = ChangedLineDiagnostics.matched(
            [
                diagnostic("/w/a.swift", 1), diagnostic("/w/a.swift", 5), diagnostic("/w/a.swift", 4),
                diagnostic("/w/new.swift", 6), diagnostic("/w/new.swift", 1), diagnostic("/w/other.swift", 3),
            ],
            lineMap: Self.lineMap,
            changes: Self.changes,
            workspace: "/w"
        )
        #expect(matched.map { "\($0.path):\($0.line)" } == ["a.swift:3", "old.swift:5"])
        #expect(dropped == 2)
    }

    @Test("a path the line map doesn't know keeps its lines")
    func unknownPath() {
        // `old.swift` is the head's name for the built commit's `new.swift`.
        let (matched, dropped) = ChangedLineDiagnostics.matched(
            [diagnostic("old.swift", 5)],
            lineMap: Self.lineMap,
            changes: Self.changes,
            workspace: "/w"
        )
        #expect(matched.map(\.line) == [5])
        #expect(dropped == 0)
    }

    @Test("line numbers at the extremes neither trap nor match", arguments: [Int.min, -1, 0, Int.max])
    func extremeLines(line: Int) {
        let (matched, _) = ChangedLineDiagnostics.matched(
            [diagnostic("a.swift", line), diagnostic("new.swift", line), diagnostic("b.swift", line)],
            lineMap: Self.lineMap,
            changes: Self.changes,
            workspace: "/w"
        )
        #expect(matched.isEmpty)
    }

    @Test("a finding's text is the escaped message and the rule as a code span, either alone if the other is empty")
    func findingText() {
        let finding = { (message: String, rule: String?) in
            ChangedLineDiagnostics.finding(for: MatchedDiagnostic(
                path: "a.swift", line: 1, column: 2, severity: .note, message: message, rule: rule
            )).text
        }
        #expect(finding("a *b*", "r`s") == "a \\*b\\* (``r`s``)")
        #expect(finding("", "r") == "`r`")
        #expect(finding("m", nil) == "m")
        #expect(finding("", nil).isEmpty)
    }
}
