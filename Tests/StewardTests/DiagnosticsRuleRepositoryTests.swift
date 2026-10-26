import Foundation
@testable import Steward
import Testing

/// The rule in a repository whose base moved after the pull request
/// branched: a report from the merge commit Actions builds is in that
/// commit's lines and paths, and the summary is in the head's.
@Suite("The diagnostics rule on a merge commit whose base moved")
struct DiagnosticsRuleRepositoryTests {
    private static let rule = "Diagnostics on changed lines"

    /// The rule's findings for a SwiftLint report of `lines`, written to
    /// `reports/swiftlint.log` in the checkout, and what it logged.
    private func run(
        _ fixture: PullRequestFixture,
        lines: [String],
        builtAt commit: String? = nil
    ) async throws -> (findings: [Finding], log: [String]) {
        try fixture.repository.write(lines.map { "\($0)\n" }.joined(), to: "reports/swiftlint.log")
        let context = try await Context.actions(environment: fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        ))
        let console = RecordingConsole()
        let rule = Rule.diagnosticsOnChangedLines(in: [.swiftLint("reports/swiftlint.log", builtAt: commit)])
        let findings = try await [rule].findings(in: context, log: Log(mode: .dryRun, console: console.console))
        let log = await console.finish().map { entry in
            switch entry {
            case .output(let text), .error(let text): text
            }
        }
        return (findings, log.joined().split(separator: "\n").map(String.init))
    }

    private func warning(_ path: String, _ line: Int, _ message: String) -> Finding {
        Finding(kind: .warning, text: "\(message) (`r`)", location: Location(path: path, line: line), rule: Self.rule)
    }

    @Test("a report from the merge commit lands on head lines and paths, and lines the base wrote are dropped")
    func mergeCommit() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }

        let (findings, log) = try await run(fixture, lines: [
            // The base inserted three lines at the top of `a.swift`.
            "\(fixture.repository.path)/a.swift:2:1: warning: base line (r)",
            "a.swift:13:1: warning: changed 10 (r)",
            "a.swift:18:1: warning: changed 15 (r)",
            "a.swift:8:1: warning: line 5 (r)",
            // And renamed `moved.swift`, inserting two lines at its top.
            "relocated.swift:7:1: warning: changed 5 (r)",
            "relocated.swift:1:1: warning: base line (r)",
            "\(PullRequestFixture.quotedPath):1:1: warning: new (r)",
            "new.swift:3:1: warning: renamed, unchanged (r)",
        ])
        #expect(findings == [
            warning("a.swift", 10, "changed 10"),
            warning("a.swift", 15, "changed 15"),
            warning(PullRequestFixture.quotedPath, 1, "new"),
            warning("moved.swift", 5, "changed 5"),
        ])
        #expect(log.first == """
            SwiftLint output reports/swiftlint.log: 8 diagnostics, 4 on changed lines, 2 dropped for lines the head \
            commit doesn't have
            """)
    }

    @Test("a report built at another commit is mapped from that commit", arguments: [false, true])
    func builtAtHead(byName: Bool) async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        try fixture.repository.git(["branch", "--quiet", "pr-head", fixture.head])

        let (findings, log) = try await run(fixture, lines: [
            "a.swift:10:1: warning: changed 10 (r)",
            "a.swift:13:1: warning: line 13 (r)",
            "moved.swift:5:1: warning: changed 5 (r)",
        ], builtAt: byName ? "pr-head" : fixture.head)
        #expect(findings == [warning("a.swift", 10, "changed 10"), warning("moved.swift", 5, "changed 5")])
        let counts = "3 diagnostics, 2 on changed lines, 0 dropped for lines the head commit doesn't have"
        #expect(log.first == "SwiftLint output reports/swiftlint.log: \(counts)")
    }

    @Test("naming the built commit itself is the same as naming none", arguments: ["HEAD", "merge"])
    func builtAtBuilt(name: String) async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let lines = ["a.swift:13:1: warning: changed 10 (r)", "a.swift:2:1: warning: base line (r)"]

        let named = try await run(fixture, lines: lines, builtAt: name)
        let unnamed = try await run(fixture, lines: lines)
        #expect(named.findings == [warning("a.swift", 10, "changed 10")])
        #expect(named.findings == unnamed.findings)
        #expect(named.log == unnamed.log)
    }

    @Test("a report built at a commit the checkout doesn't have is one failure, and reads nothing")
    func builtAtMissingCommit() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }

        let lines = ["a.swift:13:1: warning: changed 10 (r)"]
        let (findings, log) = try await run(fixture, lines: lines, builtAt: "no-such")
        #expect(findings == [Finding(
            kind: .failure,
            text: """
                The SwiftLint output `reports/swiftlint.log`, built at `no-such`, can't be read: the checkout has \
                no such commit.
                """,
            rule: Self.rule
        )])
        #expect(log == ["\(Self.rule): 1 finding, 1 failing"])
    }
}
