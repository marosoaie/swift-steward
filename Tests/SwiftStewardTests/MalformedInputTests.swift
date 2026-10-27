import Testing
@testable import BuildLogKit

/// Regression tests for hostile or malformed log input: none of these may
/// crash, and recoverable damage must stay contained. The diff-side
/// regressions live with the parser in the git-diff-parser library.
@Suite("Malformed input")
struct MalformedInputTests {
    @Test("clang 'fatal error:' diagnostics are recognized as errors")
    func fatalErrorSeverity() {
        let log = "/repo/t.c:1:10: fatal error: 'nope.h' file not found"
        #expect(ClangStyleLogParser.diagnostics(in: log) == [
            Diagnostic(
                path: "/repo/t.c", line: 1, column: 10,
                severity: .error, message: "'nope.h' file not found"
            ),
        ])
    }

    @Test("a SonarQube start offset at Int.max leaves the column out instead of overflowing")
    func sonarOffsetOverflow() {
        let report = """
            {"issues": [{"component": "p:A.swift", "line": 3, "message": "m",
              "textRange": {"startLine": 3, "startOffset": \(Int.max)}}]}
            """
        #expect(SonarReportParser.diagnostics(in: report) == [
            Diagnostic(path: "A.swift", line: 3, column: nil, severity: .note, message: "m"),
        ])
    }
}
