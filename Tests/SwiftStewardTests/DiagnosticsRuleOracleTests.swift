import DiffDiagnostics
import Foundation
import GitDiffKit
@testable import Steward
import Testing

/// Steward's rule, held to `steward filter` on the real swift-argument-parser
/// logs and the 1.0.0 → 1.5.0 diff: built at the head, the rule must find
/// exactly the diagnostics `filter --repo-root <workspace>` prints, in the
/// same order. The logs' paths start with `/ci/swift-argument-parser`, so
/// that workspace strips them, and any other leaves them to the suffix
/// match.
@Suite(
    "Steward's diagnostics rule against steward filter",
    .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
)
struct DiagnosticsRuleOracleTests {
    private static let logs: [String: String] = [
        "xcodebuild": "xcodebuild.log",
        "swiftlint": "swiftlint.log",
        "swiftformat": "swiftformat.log",
        "sonar": "sonar-issues.json",
    ]

    @Test(
        "the rule finds what filter prints, on each kind of report",
        arguments: ["xcodebuild", "swiftlint", "swiftformat", "sonar"],
        ["/ci/swift-argument-parser", "/elsewhere"]
    )
    func matchesFilter(tool: String, workspace: String) async throws {
        let diff = try await RealWorldFixtureStore.localDiffURL(for: .swiftArgumentParser)
        let log = try Self.log(for: tool)
        let output = try CommandLineTool.run(arguments: [
            "filter", log, "--diff", diff.path, "--tool", tool, "--format", "json", "--repo-root", workspace,
        ])
        let matched = try JSONDecoder().decode([MatchedDiagnostic].self, from: output)

        let rule = Rule.diagnosticsOnChangedLines(in: [Self.source(tool, log)])
        let context = try Self.context(diff: diff, workspace: workspace)
        let findings = try await [rule].findings(in: context, log: .discarding)

        #expect(!matched.isEmpty)
        #expect(findings == matched.map { diagnostic in
            var finding = ChangedLineDiagnostics.finding(for: diagnostic, failingOn: .error)
            finding.rule = rule.name
            return finding
        })
    }

    @Test(
        "failing on a severity, the rule fails exactly when filter --fail-on does, on the diagnostics at or above it",
        arguments: ["xcodebuild", "swiftlint", "swiftformat", "sonar"],
        [DiagnosticSeverity.note, .warning, .error]
    )
    func failsOn(tool: String, severity: DiagnosticSeverity) async throws {
        let diff = try await RealWorldFixtureStore.localDiffURL(for: .swiftArgumentParser)
        let log = try Self.log(for: tool)
        let workspace = "/ci/swift-argument-parser"
        let rule = Rule.diagnosticsOnChangedLines(in: [Self.source(tool, log)], failingOn: severity)
        let context = try Self.context(diff: diff, workspace: workspace)
        let findings = try await [rule].findings(in: context, log: .discarding)
        let failures = findings.filter { $0.kind == .failure }

        // `run` throws unless filter exits as the rule's failures say it should.
        let output = try CommandLineTool.run(
            arguments: [
                "filter", log, "--diff", diff.path, "--tool", tool, "--format", "json", "--repo-root", workspace,
                "--fail-on", "\(severity)",
            ],
            exitCode: failures.isEmpty ? 0 : 1
        )
        let matched = try JSONDecoder().decode([MatchedDiagnostic].self, from: output)
        #expect(failures.map(\.location) == matched
            .filter { DiagnosticSeverity($0.severity) >= severity }
            .map { Location(path: $0.path, line: $0.line) })
    }

    @Test(
        "the lines the rule matches against are the ones filter reads from the same real diff",
        arguments: [RealWorldFixture.swiftArgumentParser, .redis]
    )
    func addedLines(fixture: RealWorldFixture) async throws {
        let bytes = [UInt8](try Data(contentsOf: try await RealWorldFixtureStore.localDiffURL(for: fixture)))
        let changes = GitChanges(diff: Diff(diff: bytes), commits: [], mergeBase: "a", head: "b")
        #expect(changes.addedLines == ChangedLines(diff: String(decoding: bytes, as: UTF8.self)))
    }

    /// The real swift-argument-parser report `tool` reads.
    private static func log(for tool: String) throws -> String {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return fixtures.appendingPathComponent("swift-argument-parser-1.5.0/\(try #require(logs[tool]))").path
    }

    private static func source(_ tool: String, _ log: String) -> DiagnosticSource {
        switch tool {
        case "xcodebuild": .xcodebuild(log)
        case "swiftlint": .swiftLint(log)
        case "swiftformat": .swiftFormat(log)
        default: .sonar(log)
        }
    }

    /// A pull request whose changes are the diff at `diff`, built at its
    /// head, so the line map is the identity.
    private static func context(diff: URL, workspace: String) throws -> Context {
        let head = "4c95447a3d2f8e1b0c9d7e6f5a4b3c2d1e0f9a8b"
        let base = "1ca8c39b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e7d"
        return Context(
            pullRequest: PullRequest(
                number: 1,
                title: "1.0.0 to 1.5.0",
                body: "",
                author: "ada",
                state: .open,
                isDraft: false,
                base: PullRequest.Branch(name: "main", commit: base, repository: "apple/swift-argument-parser"),
                head: PullRequest.Branch(name: "next", commit: head, repository: "apple/swift-argument-parser"),
                labels: [],
                webURL: "https://github.com/apple/swift-argument-parser/pull/1",
                additions: 0,
                deletions: 0,
                changedFiles: 0,
                commits: 0
            ),
            git: GitChanges(
                diff: Diff(diff: [UInt8](try Data(contentsOf: diff))),
                commits: [],
                mergeBase: base,
                head: head
            ),
            run: Run(
                mode: .dryRun,
                workspace: workspace,
                builtCommit: head,
                lineMap: .identity,
                apiURL: try #require(URL(string: "https://api.github.com")),
                serverURL: try #require(URL(string: "https://github.com"))
            )
        )
    }
}
