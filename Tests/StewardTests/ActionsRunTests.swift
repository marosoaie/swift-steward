@testable import DangerfileFixture
import Foundation
import PullRequestHosting
@testable import Steward
import Testing

/// The context of the pull request whose checks run these tests, from the
/// environment, payload and checkout Actions set up for real.
///
/// Runs only in a `pull_request` workflow run. The macOS job checks out
/// with `fetch-depth: 0`, so its context, and what the fixture Dangerfile
/// run as a process reports, are checked against git; the Linux job's
/// checkout has depth 1, so the context and the run must refuse it.
@Suite(
    "This pull request's own Actions run",
    .enabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"),
    .enabled(if: ProcessInfo.processInfo.environment["GITHUB_EVENT_NAME"] == "pull_request")
)
struct ActionsRunTests {
    static let environment = ProcessInfo.processInfo.environment
    // Not asked of git: the oracle's git reads no global configuration, so
    // in the Linux container it would refuse a checkout the runner owns.
    static let isShallow = FileManager.default.fileExists(
        atPath: "\(environment["GITHUB_WORKSPACE"] ?? "")/.git/shallow"
    )

    @Test("a full checkout's context matches git, the payload, and GitHub's counts", .enabled(if: !isShallow))
    func fullHistory() async throws {
        let context = try await Context.actions(environment: Self.environment)
        let path = try #require(Self.environment["GITHUB_EVENT_PATH"])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        let payload = EventPayload(object: try #require(object as? [String: Any]))

        #expect(context.pullRequest.number == payload.pullRequestField("number") as? Int)
        #expect(context.pullRequest.base.commit == (try payload.sha(of: "base")))
        #expect(context.git.head == (try payload.sha(of: "head")))
        #expect(context.run.builtCommit == Self.environment["GITHUB_SHA"])
        #expect(context.run.apiURL.absoluteString == Self.environment["GITHUB_API_URL"])
        #expect(context.run.serverURL.absoluteString == Self.environment["GITHUB_SERVER_URL"])
        let oracle = GitOracle(directory: context.run.workspace)
        try oracle.verify(context.git, base: context.pullRequest.base.commit)
        try oracle.verify(context.run.lineMap, head: context.git.head, built: context.run.builtCommit)
        context.expectCountsMatchGitHub()
    }

    @Test("the fixture Dangerfile, run here as a workflow runs it, reports what git finds", .enabled(if: !isShallow))
    func fixtureDangerfile() throws {
        let path = try #require(Self.environment["GITHUB_EVENT_PATH"])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        let payload = EventPayload(object: try #require(object as? [String: Any]))
        let base = try payload.sha(of: "base")
        let head = try payload.sha(of: "head")
        let oracle = GitOracle(directory: try #require(Self.environment["GITHUB_WORKSPACE"]))
        // GitHub's order, which RealPullRequestTests holds Steward to.
        let commits = try oracle.text(["rev-list", "--reverse", "--date-order", "\(base)..\(head)"])
            .split(separator: "\n").map(String.init)
        let title = try #require(payload.pullRequestField("title") as? String)
        let expectation = try FixtureExpectation(
            oracle: oracle,
            base: base,
            head: head,
            counts: FixtureExpectation.Counts(payload: payload),
            commits: commits,
            asksToThrow: title.contains(FixtureChecks.throwMarker)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let summaryURL = directory.appendingPathComponent("summary.md")
        try Data().write(to: summaryURL)
        // Not the job's own summary, which would show the fixture's
        // findings, failures included, on a green run.
        var environment = Self.environment
        environment["GITHUB_STEP_SUMMARY"] = summaryURL.path
        // Nor this pull request's comments: the fixture posts nothing.
        environment["GITHUB_TOKEN"] = nil
        let outcome = try FixtureDangerfile.run(["--report", "report.json"], environment: environment, in: directory)

        let repository = try #require(Self.environment["GITHUB_REPOSITORY"])
        let number = try #require(payload.pullRequestField("number") as? Int)
        let expected = expectation.report(repository: repository, pullRequest: number, head: head)
        #expect(outcome.status == expectation.status, "\(outcome.log)")
        let report = try JSONDecoder().decode(
            Report.self,
            from: Data(contentsOf: directory.appendingPathComponent("report.json"))
        )
        #expect(report == expected)
        let serverURL = try #require(URL(string: Self.environment["GITHUB_SERVER_URL"] ?? ""))
        let runID = try #require(Self.environment["GITHUB_RUN_ID"])
        let summary = Summary(
            report: expected,
            serverURL: serverURL,
            origin: .workflowRun(serverURL.appendingPathComponent("\(repository)/actions/runs/\(runID)")),
            unlinkedPaths: expectation.unlinkedPaths
        )
        #expect(String(decoding: try Data(contentsOf: summaryURL), as: UTF8.self) == summary.text)
        // A fork's pull request is skipped before the token is looked at.
        let isFromFork = payload.repository(of: "head") != payload.repository(of: "base")
        #expect(outcome.log.contains(isFromFork
            ? "::notice title=Steward::The pull request comes from \(payload.repository(of: "head") ?? ""), a fork"
            : "::warning title=Steward::GITHUB_TOKEN isn't set"))
    }

    @Test("a depth-1 checkout is refused with the history it lacks", .enabled(if: isShallow))
    func shallowHistory() async throws {
        let error = await #expect(throws: ContextError.self) {
            try await Context.actions(environment: Self.environment)
        }
        let isHistoryError = switch error {
        case .missingCommit?, .noMergeBase(_, _, isShallow: true)?: true
        default: false
        }
        #expect(isHistoryError, "\(error.map(String.init(describing:)) ?? "no error")")
        #expect(error?.description.contains("fetch-depth: 0") == true)
    }

    @Test("the fixture Dangerfile, run here on a depth-1 checkout, exits 2 with the fix", .enabled(if: isShallow))
    func shallowFixtureDangerfile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = Self.environment
        environment["GITHUB_STEP_SUMMARY"] = directory.appendingPathComponent("summary.md").path
        let outcome = try FixtureDangerfile.run([], environment: environment, in: directory)
        #expect(outcome.status == 2)
        #expect(outcome.log.contains("::error title=Steward::"))
        #expect(outcome.log.contains("fetch-depth: 0"))
    }
}
