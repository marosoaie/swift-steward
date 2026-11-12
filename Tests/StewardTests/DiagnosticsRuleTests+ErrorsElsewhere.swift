@testable import Steward
import Testing

/// A build log's errors that aren't on lines the pull request adds.
extension DiagnosticsRuleTests {
    @Test("a build log's errors off the changed lines are one more failure, listed at their places in the log")
    func errorsElsewhere() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let path = try reports.write("""
            /workspace/Sources/A.swift:2:1: error: on a changed line
            error: SwiftCompile normal arm64 /workspace/Sources/A.swift failed with a nonzero exit code
            /workspace/Sources/A.swift:3:1: error: on an unchanged line
            /elsewhere/Sources/C.swift:1:1: error: in an unchanged *file*
            /workspace/Sources/C.swift:2:1: warning: a warning elsewhere
            error: Build failed

            """, to: "build.log")

        let (findings, _) = try await run([.xcodebuild(path)])
        #expect(findings == [
            Finding(
                kind: .failure,
                text: "on a changed line",
                location: Location(path: "Sources/A.swift", line: 2),
                rule: "Diagnostics on changed lines"
            ),
            Finding(
                kind: .failure,
                text: """
                    Errors in the xcodebuild log \(Markdown.codeSpan(path)) that aren't on lines the pull request adds:
                    `Sources/A.swift:3`: on an unchanged line
                    `/elsewhere/Sources/C.swift:1`: \(Markdown.escaped("in an unchanged *file*"))
                    """,
                rule: "Diagnostics on changed lines"
            ),
        ])
    }

    @Test("a log without located errors lists its unlocated ones, as a linker's failure gives")
    func unlocatedErrors() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let path = try reports.write("""
            Undefined symbols for architecture arm64:
              "_missing", referenced from:
            ld: symbol(s) not found for architecture arm64
            clang: error: linker command failed with exit code 1 (use -v to see invocation)
            error: Multiple commands produce '/Build/App.app/Info.plist'
            /workspace/Sources/A.swift:2:1: warning: on a changed line

            """, to: "build.log")

        let (findings, _) = try await run([.xcodebuild(path)])
        #expect(findings.map(\.kind) == [.warning, .failure])
        #expect(findings.last?.text == """
            Errors in the xcodebuild log \(Markdown.codeSpan(path)) that aren't on lines the pull request adds:
            \(Markdown.escaped("linker command failed with exit code 1 (use -v to see invocation)"))
            \(Markdown.escaped("Multiple commands produce '/Build/App.app/Info.plist'"))
            """)
        #expect(findings.last?.location == nil)
    }

    @Test("the list stops at five, an earlier build log's errors aren't listed again, and a lint's aren't listed")
    func errorsElsewhereAcrossReports() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let errors = (1...7).map { "/workspace/Sources/C.swift:\($0):1: error: e\($0)\n" }.joined()
        let first = try reports.write(errors, to: "macos.log")
        let second = try reports.write(errors + "/workspace/Sources/C.swift:8:1: error: e8\n", to: "ios.log")
        let lint = try reports.write("/workspace/Sources/C.swift:1:1: error: Force Cast (force_cast)\n", to: "lint.log")

        let (findings, log) = try await run([.xcodebuild(first), .xcodebuild(second), .swiftLint(lint)])
        let subject = "that aren't on lines the pull request adds:"
        #expect(findings.map(\.text) == [
            """
            Errors in the xcodebuild log \(Markdown.codeSpan(first)) \(subject)
            `Sources/C.swift:1`: e1
            `Sources/C.swift:2`: e2
            `Sources/C.swift:3`: e3
            `Sources/C.swift:4`: e4
            `Sources/C.swift:5`: e5
            and 2 more
            """,
            """
            Errors in the xcodebuild log \(Markdown.codeSpan(second)) \(subject)
            `Sources/C.swift:8`: e8
            """,
        ])
        #expect(log.contains("""
            xcodebuild log \(second): 7 errors elsewhere left out, the same as one an earlier report gave
            """))
    }

    @Test("a name of its own names the rule")
    func named() {
        #expect(Rule.diagnosticsOnChangedLines(in: [], named: "iOS build").name == "iOS build")
    }
}
