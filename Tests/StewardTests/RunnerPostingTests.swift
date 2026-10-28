@testable import DangerfileFixture
import Foundation
@testable import Steward
import Testing

/// Whole CI runs that post the summary comment, in-process, over
/// `PullRequestFixture` and `FakeGitHub`.
@Suite("A CI run's summary comment")
struct RunnerPostingTests {
    static let marker = "<!-- steward-summary -->\n"
    static let failing = [Rule("Size") { _ in [.failure("Too big")] }]
    static let passing = [Rule("Thanks") { _ in [.message("Thanks!")] }]
    static let runURL = "https://github.com/marosoaie/swift-steward/actions/runs/42"
    static let list = "GET /repos/marosoaie/swift-steward/issues/21/comments?per_page=100&page=1"
    static let read = "GET /repos/marosoaie/swift-steward/pulls/21"
    static let create = "POST /repos/marosoaie/swift-steward/issues/21/comments"
    static let edit = "PATCH /repos/marosoaie/swift-steward/issues/comments/1001"
    static let commentURL = "https://github.com/marosoaie/swift-steward/pull/21#issuecomment-1001"

    /// A rule with `count` warnings, each with its own location, of about
    /// 150 bytes a row.
    static func warnings(_ count: Int) -> [Rule] {
        [Rule("Many") { _ in
            (1...count).map { .warning("Warning \($0), in a few more words", at: Location(path: "a.swift", line: $0)) }
        }]
    }

    @Test("a run posts the summary, the next one updates it, and a clean one turns it to all clear")
    func runs() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let github = FakeGitHub(head: fixture.head)
        let first = try await RunnerTests.run(Self.failing, on: fixture, github: github)
        #expect(first.status == .failures)
        #expect(first.comments.map(\.body) == [Self.marker + (first.jobSummary ?? "")])
        #expect(first.log.hasSuffix("""
            </sub>
            ::endgroup::
            ::group::Summary comment
            Posted the summary comment: \(Self.commentURL)
            ::endgroup::

            """))

        let second = try await RunnerTests.run(Self.passing, on: fixture, github: github)
        #expect(second.status == .clean)
        #expect(second.comments.map(\.id) == [1_001])
        #expect(second.comments.map(\.body) == [Self.marker + (second.jobSummary ?? "")])

        let third = try await RunnerTests.run([], on: fixture, github: github)
        #expect(third.status == .clean)
        #expect(third.comments.map(\.id) == [1_001])
        let allClear = "\(Self.marker)**No findings** on \(fixture.head.prefix(7))"
        #expect(third.comments.first?.body.hasPrefix(allClear) == true)
        #expect(third.log.contains("::group::Summary comment\nUpdated the summary comment: \(Self.commentURL)\n"))
        let update = [Self.list, Self.read, Self.edit]
        #expect(third.requests == [Self.list, Self.read, Self.create] + update + update)
    }

    @Test("the fixture Dangerfile's rules, run through the runner, post exactly their job summary")
    func fixtureRules() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let outcome = try await RunnerTests.run(FixtureChecks.rules, ["--report", "report.json"], on: fixture)
        let summary = try #require(outcome.jobSummary)
        let report = try #require(outcome.report)
        #expect(report.findings.count > 3)
        #expect(outcome.status == (report.hasFailures ? .failures : .clean))
        #expect(outcome.requests == [Self.list, Self.read, Self.create])
        let comment = FakeGitHub.Comment(id: 1_001, body: Self.marker + summary, login: "github-actions[bot]")
        #expect(outcome.comments == [comment])
        // Posting warned of nothing: the log's only commands of either
        // kind are the located findings' annotations, which come last.
        let annotations = report.findings.compactMap(Log.annotation(of:)).joined()
        #expect(outcome.log.hasSuffix(annotations))
        let log = outcome.log.dropLast(annotations.count)
        #expect(!log.contains("::warning") && !log.contains("::error"))
    }

    @Test("a pull request from a fork gets a notice instead of a comment, and its findings still decide the exit")
    func fork() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let environment = try RunnerTests.environment(for: fixture)
        try EventPayload.recorded("pull-request-event.opened")
            .setting(base: fixture.base, head: fixture.head)
            .repository("contributor/swift-steward", of: "head")
            .write(to: fixture.repository.eventURL)
        let outcome = try await RunnerTests.run(
            Self.failing,
            ["--fail-on-post-error"],
            on: fixture,
            environment: environment
        )
        #expect(outcome.status == .failures)
        #expect(outcome.requests.isEmpty)
        #expect(outcome.jobSummary?.hasPrefix("**1 failure** on") == true)
        #expect(outcome.log.contains("""
            ::notice title=Steward::The pull request comes from contributor/swift-steward, a fork, whose workflow \
            runs get a read-only token, so Steward doesn't post the summary comment. The findings are in this \
            run's log and job summary.

            """))
        #expect(!outcome.log.contains("::warning"))
    }

    /// Why a summary can't be posted.
    enum Breakage: String, CaseIterable {
        case noToken, forbidden, unnamedRepository
    }

    @Test("a summary that can't be posted warns, and fails the run only with --fail-on-post-error",
          arguments: Breakage.allCases, [false, true])
    func unposted(breakage: Breakage, failsOnPostError: Bool) async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let github = FakeGitHub(head: fixture.head)
        let forbidden = FakeGitHub.Failure.status(403, message: "Resource not accessible by integration")
        await github.fail("issues/create-comment", with: forbidden)
        let environment = try RunnerTests.environment(for: fixture)
        if breakage == .unnamedRepository {
            try EventPayload.recorded("pull-request-event.opened")
                .setting(base: fixture.base, head: fixture.head)
                .repository("swift-steward", of: "base", "head")
                .write(to: fixture.repository.eventURL)
        }
        let outcome = try await RunnerTests.run(
            Self.passing,
            failsOnPostError ? ["--fail-on-post-error"] : [],
            on: fixture,
            environment: environment,
            token: breakage == .noToken ? nil : FakeGitHub.token,
            github: github
        )
        #expect(outcome.status == (failsOnPostError ? .broken : .clean))
        #expect(outcome.comments.isEmpty)
        #expect(outcome.requests == (breakage == .forbidden ? [Self.list, Self.read, Self.create] : []))
        let warning = switch breakage {
        case .noToken: "GITHUB_TOKEN isn't set, so Steward can't post the summary comment: give the step"
        case .forbidden: "Couldn't post the summary comment: issues/create-comment failed (forbidden): HTTP 403"
        case .unnamedRepository: """
            The event names the repository "swift-steward", which isn't owner/name, so Steward can't post the \
            summary comment. The findings are in this run's log and job summary.
            """
        }
        #expect(outcome.log.contains("::warning title=Steward::\(warning)"))
        #expect(outcome.jobSummary?.contains("| :book: | Thanks! |") == true)
    }

    @Test("a failing run whose summary can't be posted exits 1, or 2 with --fail-on-post-error",
          arguments: [false, true])
    func unpostedFailures(failsOnPostError: Bool) async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let outcome = try await RunnerTests.run(
            Self.failing,
            failsOnPostError ? ["--fail-on-post-error"] : [],
            on: fixture,
            token: ""
        )
        #expect(outcome.status == (failsOnPostError ? .broken : .failures))
        #expect(outcome.log.contains("::warning title=Steward::GITHUB_TOKEN isn't set"))
    }

    @Test("a run whose commit was pushed over posts nothing, and exits by its findings")
    func stale() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let newer = String(repeating: "f", count: 40)
        let outcome = try await RunnerTests.run(
            Self.failing,
            ["--fail-on-post-error"],
            on: fixture,
            github: FakeGitHub(head: newer)
        )
        #expect(outcome.status == .failures)
        #expect(outcome.requests == [Self.list, Self.read])
        #expect(outcome.comments.isEmpty)
        #expect(outcome.log.contains("The pull request's head is \(newer) now, not \(fixture.head), so this run stops"))
    }

    @Test("--summary-author makes another account's summary comments the run's, a personal access token's")
    func summaryAuthor() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let github = FakeGitHub(head: fixture.head, login: "marosoaie")
        await github.addComment(Self.marker + "The workflow token's", by: "github-actions[bot]")
        let own = await github.addComment(Self.marker + "The token's own", by: "MaRosoaie")
        let outcome = try await RunnerTests.run(
            Self.passing,
            ["--summary-author", "marosoaie"],
            on: fixture,
            github: github
        )
        #expect(outcome.requests.last == "PATCH /repos/marosoaie/swift-steward/issues/comments/\(own)")
        #expect(outcome.comments.map(\.body) == [
            Self.marker + "The workflow token's", Self.marker + (outcome.jobSummary ?? ""),
        ])
    }

    @Test("a run cancelled while it pauses to retry a request exits 2, with no comment")
    func cancelled() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let github = FakeGitHub(head: fixture.head)
        await github.fail("issues/list-comments", with: .status(502, message: "Bad Gateway"))
        let outcome = try await RunnerTests.run(
            Self.passing,
            on: fixture,
            github: github,
            sleep: { _ in throw CancellationError() }
        )
        #expect(outcome.status == .broken)
        #expect(outcome.comments.isEmpty)
        #expect(outcome.log.contains("::error title=Steward::The run was cancelled while posting the summary"))
    }

    @Test("a dry run with a token and --fail-on-post-error reads the pull request, and posts nothing")
    func dryRun() async throws {
        let fixture = try DryRunTests.checkedOutFixture()
        defer { fixture.remove() }
        let github = FakeGitHub(number: 26, head: fixture.head)
        let recording = RecordingConsole()
        let status = await Runner.testing(
            ["--base", "main", "--pull-request", "26", "--fail-on-post-error"],
            environment: ["GITHUB_REPOSITORY": "marosoaie/swift-steward", "GITHUB_TOKEN": FakeGitHub.token],
            directory: fixture.repository.path,
            recording: recording,
            transport: github
        ).run(Self.failing)
        let (output, log) = await recording.finishStreams()
        #expect(status == .failures)
        #expect(await github.requests.map(\.description) == ["GET /repos/marosoaie/swift-steward/pulls/26"])
        #expect(output.hasPrefix("**1 failure** on"))
        #expect(!log.contains("comment"))
    }
}
