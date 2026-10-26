import GitDiffKit
import Foundation
@testable import Steward
import StewardVersion
import Testing

/// Whole runs in GitHub Actions mode, in-process, over `PullRequestFixture`.
@Suite("A CI run")
struct RunnerTests {
    /// What a finished run left behind.
    struct Outcome {
        var status: Steward.ExitStatus
        var output: String
        var log: String
        var jobSummary: String?
        var report: Report?
        /// Every request GitHub's fake got, this run's and earlier ones'.
        var requests: [String]
        /// The pull request's comments on GitHub's fake, after the run.
        var comments: [FakeGitHub.Comment]
    }

    static let rules = [
        Rule("Deleted files") { context in
            (context.git.deletedFiles + context.git.renamedFiles.map(\.from))
                .map { .warning("Gone: \($0)", at: Location(path: $0)) }
        },
        Rule("Edits") { _ in [.message("Line 15 changed", at: Location(path: "a.swift", line: 15))] },
        Rule("Size") { context in context.git.diff.files.count > 5 ? [.failure("Too many files")] : [] },
        Rule("Notes") { _ in [.markdown("## Notes")] },
    ]

    @Test("a run reports, appends the summary to the job summary, logs in groups, and exits 1 on a failure")
    func fullRun() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let outcome = try await Self.run(Self.rules, ["--report", "report.json"], on: fixture)
        let head = fixture.head
        let short = String(head.prefix(7))
        #expect(outcome.status == .failures)
        #expect(outcome.output.isEmpty)
        #expect(outcome.jobSummary == """
            **1 failure, 2 warnings, 1 message, 1 note** on \(short)

            | | Failures |
            |---|---|
            | :no_entry_sign: | Too many files |

            | | Warnings |
            |---|---|
            | :warning: | Gone: gone.swift<br>`gone.swift` |
            | :warning: | Gone: old.swift<br>`old.swift` |

            | | Messages |
            |---|---|
            | :book: | Line 15 changed<br>[`a.swift:15`](https://github.com/marosoaie/swift-steward/blob/\(head)/a.swift#L15) |

            ## Notes

            <sub>Steward \(Release.version) · [workflow run](https://github.com/marosoaie/swift-steward/actions/runs/42) · \(short)</sub>

            """)
        let report = try #require(outcome.report)
        #expect(report.repository == "marosoaie/swift-steward")
        #expect(report.pullRequest == 21)
        #expect(report.headCommit == head)
        #expect(report.generator == "Steward \(Release.version)")
        #expect(report.findings.map(\.rule) == ["Deleted files", "Deleted files", "Edits", "Size", "Notes"])
        #expect(outcome.log.contains("""
            ::group::Context
            Pull request #21 in marosoaie/swift-steward: claude/step-3-2-openapi-spike-b910f2 into main
            Changes from the merge base \(fixture.forkPoint) to the head \(head): 7 files, 2 commits
            Build logs refer to \(fixture.built).
            ::endgroup::
            ::group::Rules
            Deleted files: 2 findings
            Edits: 1 finding
            Size: 1 finding, 1 failing
            Notes: 1 finding
            ::endgroup::
            ::group::Summary
            **1 failure
            """))
        #expect(outcome.log.contains("</sub>\n::endgroup::\n::group::Summary comment\nPosted the summary comment: "))
    }

    @Test("a run without failures exits 0, and its summary follows what the step's summary already held")
    func clean() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let outcome = try await Self.run([], on: fixture, jobSummary: "| a | b |\n|---|---|\n| 1 | 2 |")
        let short = String(fixture.head.prefix(7))
        #expect(outcome.status == .clean)
        #expect(outcome.jobSummary == """
            | a | b |
            |---|---|
            | 1 | 2 |

            **No findings** on \(short)

            <sub>Steward \(Release.version) · [workflow run](https://github.com/marosoaie/swift-steward/actions/runs/42) · \(short)</sub>

            """)
    }

    @Test("a rule that throws fails the run with its error in the summary, and the other rules still report")
    func thrownRule() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let rules = [
            Rule("Lint") { _ in throw CocoaError(.fileReadNoSuchFile) },
            Rule("Thanks") { _ in [.message("Thanks!")] },
        ]
        let outcome = try await Self.run(rules, on: fixture)
        #expect(outcome.status == .failures)
        let summary = try #require(outcome.jobSummary)
        #expect(summary.contains("| :no_entry_sign: | Rule “Lint” failed: "))
        #expect(summary.contains("| :book: | Thanks! |"))
    }

    /// Ways a run can fail to build its context or start at all.
    enum Breakage: String, CaseIterable {
        case unknownOption, unsupportedEvent, missingPayload, shallowClone
    }

    @Test("a run that can't build its context exits 2 with an error annotation, and writes no summary or report",
          arguments: Breakage.allCases)
    func broken(breakage: Breakage) async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        var arguments = ["--report", "report.json"]
        var environment = try Self.environment(for: fixture)
        var workspace: TestRepository?
        switch breakage {
        case .unknownOption: arguments.append("--bsae")
        case .unsupportedEvent: environment["GITHUB_EVENT_NAME"] = "push"
        case .missingPayload:
            environment["GITHUB_EVENT_PATH"] = fixture.repository.root.appendingPathComponent("none").path
        case .shallowClone:
            let clone = try TestRepository(cloning: fixture.repository, options: ["--depth=1", "--branch=merge"])
            workspace = clone
            environment["GITHUB_WORKSPACE"] = clone.path
        }
        defer { workspace?.remove() }
        let outcome = try await Self.run(Self.rules, arguments, on: fixture, environment: environment)
        #expect(outcome.status == .broken)
        #expect(outcome.log.contains("::error title=Steward::"))
        #expect(outcome.jobSummary?.isEmpty == true)
        #expect(outcome.report == nil)
        #expect(!outcome.log.contains("::group::Rules"))
        #expect(outcome.requests.isEmpty)
    }

    @Test("a report that can't be written exits 2, after the summary is out")
    func unwritableReport() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let outcome = try await Self.run(Self.rules, ["--report=missing/report.json"], on: fixture)
        #expect(outcome.status == .broken)
        #expect(outcome.log.contains("::error title=Steward::Couldn't write the report to "))
        #expect(outcome.jobSummary?.hasPrefix("**1 failure, 2 warnings") == true)
    }

    @Test("--help prints the usage and exits 0 without building a context")
    func help() async {
        let recording = RecordingConsole()
        let status = await Runner.testing(["--help"], environment: [:], directory: "/nonexistent", recording: recording)
            .run(Self.rules)
        let (output, log) = await recording.finishStreams()
        #expect(status == .clean)
        #expect(output == Options.usage(program: "PullRequestChecks"))
        #expect(log.isEmpty)
    }

    @Test("a CI run ignores the dry run's options with a warning")
    func dryRunOptions() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let outcome = try await Self.run([], ["--base", "main", "--pull-request", "3"], on: fixture)
        #expect(outcome.status == .clean)
        #expect(outcome.log.hasPrefix("::warning title=Steward::--base and --pull-request are for dry runs"))
    }

    @Test("without GITHUB_STEP_SUMMARY or GITHUB_RUN_ID, the summary is in the log, without a link to the run")
    func noJobSummary() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        var environment = try Self.environment(for: fixture)
        environment["GITHUB_STEP_SUMMARY"] = nil
        environment["GITHUB_RUN_ID"] = nil
        let outcome = try await Self.run([], on: fixture, environment: environment)
        #expect(outcome.status == .clean)
        #expect(outcome.log.contains("::warning title=Steward::GITHUB_STEP_SUMMARY isn't set"))
        #expect(outcome.log.contains("<sub>Steward \(Release.version) · \(fixture.head.prefix(7))</sub>\n::endgroup::"))
    }

    @Test("findings that could pass for workflow commands are logged with commands paused")
    func untrustedSummary() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let outcome = try await Self.run([Rule("Sneaky") { _ in [.markdown("::add-mask::x")] }], on: fixture)
        #expect(outcome.log.contains("::group::Summary\n::stop-commands::T0K3N\n**1 note**"))
        #expect(outcome.log.contains("</sub>\n::T0K3N::\n::endgroup::\n"))
    }

    @Test("a cancelled run exits 2 before writing a report or a summary")
    func cancelled() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let rules = [Rule("Cancels") { _ in
            unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
            return [.failure("never shown")]
        }]
        let outcome = try await Self.run(rules, ["--report", "report.json"], on: fixture)
        #expect(outcome.status == .broken)
        #expect(outcome.log.contains("::error title=Steward::The run was cancelled"))
        #expect(outcome.jobSummary?.isEmpty == true)
        #expect(outcome.report == nil)
        #expect(outcome.requests.isEmpty)
    }

    /// The environment of a run on the fixture's pull request, its job
    /// summary file and workflow run included.
    static func environment(for fixture: PullRequestFixture) throws -> [String: String] {
        try fixture.repository.actionsEnvironment(base: fixture.base, head: fixture.head, built: fixture.built)
            .merging([
                "GITHUB_STEP_SUMMARY": fixture.repository.root.appendingPathComponent("summary.md").path,
                "GITHUB_REPOSITORY": "marosoaie/swift-steward",
                "GITHUB_RUN_ID": "42",
            ]) { $1 }
    }

    /// Runs `rules` with `arguments` on the fixture, from the fixture's
    /// root directory, with an empty job summary file unless `jobSummary`
    /// says what it holds, and with `token` as GITHUB_TOKEN for `github`,
    /// a fake whose pull request's head is the fixture's unless it's given.
    static func run(
        _ rules: [Rule],
        _ arguments: [String] = [],
        on fixture: PullRequestFixture,
        environment: [String: String]? = nil,
        jobSummary: String = "",
        token: String? = FakeGitHub.token,
        github: FakeGitHub? = nil,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) async throws -> Outcome {
        var environment = try environment ?? Self.environment(for: fixture)
        environment["GITHUB_TOKEN"] = token
        let github = github ?? FakeGitHub(head: fixture.head)
        let root = fixture.repository.root
        try Data(jobSummary.utf8).write(to: root.appendingPathComponent("summary.md"))
        let recording = RecordingConsole()
        var runner = Runner.testing(
            arguments,
            environment: environment,
            directory: root.path,
            recording: recording,
            transport: github
        )
        runner.sleep = sleep ?? runner.sleep
        let status = await runner.run(rules)
        let (output, log) = await recording.finishStreams()
        let summaryURL = environment["GITHUB_STEP_SUMMARY"].map { URL(fileURLWithPath: $0) }
        let reportData = try? Data(contentsOf: root.appendingPathComponent("report.json"))
        return Outcome(
            status: status,
            output: output,
            log: log,
            jobSummary: try summaryURL.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) },
            report: try reportData.map { try JSONDecoder().decode(Report.self, from: $0) },
            requests: await github.requests.map(\.description),
            comments: await github.comments
        )
    }
}
