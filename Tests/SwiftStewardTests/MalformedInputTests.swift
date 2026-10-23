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
}
