import Foundation
@testable import Steward
import Testing

@Suite("The built-in rule for diagnostics on changed lines")
struct DiagnosticsRuleTests {
    /// Adds lines 2 and 4 of `Sources/A.swift` and both lines of the new
    /// `Sources/B.swift`.
    private static let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 1111111..2222222 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1,3 +1,4 @@
         one
        +two
         three
        -four
        +five
        diff --git a/Sources/B.swift b/Sources/B.swift
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/Sources/B.swift
        @@ -0,0 +1,2 @@
        +one
        +two

        """

    /// Files written to a fresh directory, for reports to read.
    private struct Reports {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("steward-reports-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        /// Writes `contents` to `name` and returns the file's absolute path.
        func write(_ contents: String, to name: String) throws -> String {
            try write(Data(contents.utf8), to: name)
        }

        func write(_ contents: Data, to name: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            try contents.write(to: url)
            return url.path
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The rule's findings and what it logged, run as the runner runs it.
    private func run(
        _ sources: [DiagnosticSource],
        in context: Context = .stub(diff: diff)
    ) async throws -> (findings: [Finding], log: [String]) {
        let console = RecordingConsole()
        let rule = Rule.diagnosticsOnChangedLines(in: sources)
        let findings = try await [rule].findings(in: context, log: Log(mode: .dryRun, console: console.console))
        let log = await console.finish().map { entry in
            switch entry {
            case .output(let text), .error(let text): text
            }
        }
        return (findings, log.joined().split(separator: "\n").map(String.init))
    }

    @Test("SwiftLint violations on added lines become warnings at their lines, and the rest are left out")
    func swiftLint() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let path = try reports.write("""
            /workspace/Sources/A.swift:1:1: warning: Trailing Whitespace Violation: Remove it (trailing_whitespace)
            /workspace/Sources/A.swift:2:5: warning: Line Length Violation: Too long (line_length)
            /workspace/Sources/B.swift:2:1: error: Force Cast Violation: Don't (force_cast)
            /workspace/Sources/C.swift:2:1: warning: Line Length Violation: Too long (line_length)

            """, to: "swiftlint.log")

        let (findings, log) = try await run([.swiftLint(path)])
        #expect(findings == [
            Finding(
                kind: .warning,
                text: "Line Length Violation: Too long (`line_length`)",
                location: Location(path: "Sources/A.swift", line: 2),
                rule: "Diagnostics on changed lines"
            ),
            Finding(
                kind: .failure,
                text: "Force Cast Violation: Don't (`force_cast`)",
                location: Location(path: "Sources/B.swift", line: 2),
                rule: "Diagnostics on changed lines"
            ),
        ])
        #expect(log == [
            """
            SwiftLint output \(path): 4 diagnostics, 2 on changed lines, 0 dropped for lines the head commit \
            doesn't have
            """,
            "Diagnostics on changed lines: 2 findings, 1 failing",
        ])
    }

    @Test("an error fails the check, a warning warns, and a note informs")
    func severities() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let path = try reports.write("""
            Sources/A.swift:2:1: error: cannot find 'x' in scope
            Sources/A.swift:4:1: warning: unused variable 'y' [-Wunused-variable]
            Sources/B.swift:1:1: note: did you mean 'z'?

            """, to: "build.log")

        let (findings, _) = try await run([.xcodebuild(path)])
        #expect(findings.map(\.kind) == [.failure, .warning, .message])
        #expect(findings.map(\.text) == [
            "cannot find 'x' in scope", "unused variable 'y' (`-Wunused-variable`)", "did you mean 'z'?",
        ])
    }

    @Test("each kind of report is read with its own parser")
    func kinds() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let swiftFormat = try reports.write("""
            /workspace/Sources/A.swift:4:1: warning: (indent) Indent code.

            """, to: "swiftformat.log")
        let sonar = try reports.write("""
            {"issues": [{"rule": "swift:S1481", "severity": "MAJOR", "status": "OPEN", \
            "component": "o:r:Sources/B.swift", "line": 1, "message": "Remove this variable."}]}
            """, to: "sonar.json")

        let (findings, _) = try await run([.swiftFormat(swiftFormat), .sonar(sonar)])
        #expect(findings.map(\.text) == ["Indent code. (`indent`)", "Remove this variable. (`swift:S1481`)"])
        #expect(findings.map(\.location) == [
            Location(path: "Sources/A.swift", line: 4), Location(path: "Sources/B.swift", line: 1),
        ])
    }

    @Test("a tool's text can't render as Markdown or HTML, or mention anyone", arguments: [
        "<img src=x onerror=alert(1)>", "**bold** _it_ ~gone~", "[click](https://example.com)", "cc @octocat",
        "`code` & <!-- comment -->", "| a | b |",
    ])
    func hostileText(message: String) async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let path = try reports.write("Sources/A.swift:2:1: warning: \(message)\n", to: "build.log")

        let (findings, _) = try await run([.xcodebuild(path)])
        #expect(findings.map(\.text) == [Markdown.escaped(message)])
    }

    @Test("a relative path starts from the workspace, not the current directory")
    func relativePath() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        _ = try reports.write("Sources/A.swift:2:1: warning: w\n", to: "build.log")
        var context = Context.stub(diff: Self.diff)
        context.run.workspace = reports.directory.path

        let (findings, _) = try await run([.xcodebuild("build.log")], in: context)
        #expect(findings.map(\.location) == [Location(path: "Sources/A.swift", line: 2)])
    }

    @Test("a report that can't be read is one failure, and the reports after it are still read")
    func missingReport() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let path = try reports.write("Sources/A.swift:2:1: warning: w\n", to: "build.log")
        let missing = reports.directory.appendingPathComponent("missing `log`.txt").path

        let (findings, log) = try await run([.swiftLint(missing), .xcodebuild(path)])
        #expect(findings.map(\.kind) == [.failure, .warning])
        #expect(findings.first?.text.hasPrefix("Couldn't read the SwiftLint output ``\(missing)``: ") == true)
        #expect(findings.first?.location == nil)
        #expect(log.first?.hasPrefix("xcodebuild log \(path): 1 diagnostic, 1 on changed lines") == true)
    }

    @Test("a directory is a report that can't be read")
    func directoryReport() async throws {
        let reports = try Reports()
        defer { reports.remove() }

        let (findings, _) = try await run([.sonar(reports.directory.path)])
        #expect(findings.map(\.kind) == [.failure])
    }

    @Test("a report its parser doesn't recognize gives no diagnostics, and says so in the log", arguments: [
        Data("{\"issues\": [".utf8), Data([0xFF, 0xFE, 0x00, 0x89, 0x50, 0x4E, 0x47, 0x0A]), Data(),
        Data("Sources/A.swift:99999999999999999999:1: warning: huge\n".utf8),
    ])
    func unrecognizedReport(contents: Data) async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let sonar = try reports.write(contents, to: "sonar.json")
        let build = try reports.write(contents, to: "build.log")

        let (findings, log) = try await run([.sonar(sonar), .xcodebuild(build)])
        #expect(findings.isEmpty)
        let counts = "0 diagnostics, 0 on changed lines, 0 dropped for lines the head commit doesn't have"
        #expect(log.prefix(2) == ["SonarQube report \(sonar): \(counts)", "xcodebuild log \(build): \(counts)"])
    }

    @Test("no reports, no findings")
    func noSources() async throws {
        let (findings, log) = try await run([])
        #expect(findings.isEmpty)
        #expect(log == ["Diagnostics on changed lines: 0 findings"])
    }

    @Test("called outside a run, the rule returns the same findings and logs nothing")
    func evaluate() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        let path = try reports.write("Sources/A.swift:2:1: warning: w\n", to: "build.log")
        let rule = Rule.diagnosticsOnChangedLines(in: [.xcodebuild(path)])

        let findings = try await rule.evaluate(Context.stub(diff: Self.diff))
        #expect(findings == [.warning("w", at: Location(path: "Sources/A.swift", line: 2))])
        #expect(rule.name == "Diagnostics on changed lines")
    }

    @Test("a rule's check set through `evaluate` replaces the built-in one")
    func replacedEvaluate() async throws {
        var rule = Rule.diagnosticsOnChangedLines(in: [.xcodebuild("/no/such/log")])
        rule.evaluate = { _ in [.message("replaced")] }

        #expect(try await rule.evaluate(Context.stub()).map(\.text) == ["replaced"])
        #expect(try await rule.findings(in: Context.stub(), log: .discarding).map(\.text) == ["replaced"])
    }
}
