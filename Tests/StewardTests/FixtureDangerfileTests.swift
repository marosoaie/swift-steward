@testable import DangerfileFixture
import Foundation
@testable import Steward
import StewardVersion
import Testing

/// The fixture Dangerfile (`FixtureChecks`) on merged pull requests of this
/// project's two repositories: run as its own process, as a workflow runs
/// it, and as a dry run on a checkout of the head, both in-process, where
/// any request fails the test, and as a process. Each run's report,
/// summary and exit status are checked against what git and GitHub say.
///
/// Uses the mirrors `RealPullRequestTests` clones; set
/// `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS` to skip. Serialized, so two tests
/// never fetch into the same mirror at once.
@Suite(
    "The fixture Dangerfile on real pull requests",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
)
struct FixtureDangerfileTests {
    /// A merged pull request, recorded in Fixtures/pulls, and the mirror
    /// that holds its commits.
    struct Merged {
        let name: String
        /// `owner/name`.
        let repository: String
        let number: Int
        let payload: EventPayload
        let base: String
        let head: String
        /// The merge commit, which stands in for the test merge Actions
        /// builds.
        let merge: String
        let mirror: URL

        init(_ name: String) throws {
            self.name = name
            let repositoryName = RealPullRequestTests.repository(of: name)
            repository = "marosoaie/\(repositoryName)"
            payload = try EventPayload.pullRequest(name)
            number = try #require(payload.pullRequestField("number") as? Int)
            base = try payload.sha(of: "base")
            head = try payload.sha(of: "head")
            merge = try #require(payload.pullRequestField("merge_commit_sha") as? String)
            mirror = try RepositoryMirror.local(repositoryName, having: [base, head, merge])
        }

        func expectation(asksToThrow: Bool = false) throws -> FixtureExpectation {
            try FixtureExpectation(
                oracle: GitOracle(directory: mirror.path),
                base: base,
                head: head,
                counts: FixtureExpectation.Counts(payload: payload),
                commits: RealPullRequestTests.recordedCommits(name),
                asksToThrow: asksToThrow
            )
        }
    }

    /// What a workflow run left behind.
    struct WorkflowRun {
        var outcome: FixtureDangerfile.Outcome
        var report: Report?
        var jobSummary: String
    }

    static let pullRequests = [
        "swift-steward-17", "swift-steward-20", "swift-steward-22", "swift-steward-24", "swift-steward-26",
        "git-diff-parser-1", "git-diff-parser-2", "git-diff-parser-5", "git-diff-parser-8",
    ]

    /// The job summary of each pull request's workflow run, as `Fingerprint`
    /// pins it with the footer's version taken out (`versionless`), so macOS
    /// and Linux write the same bytes, and a release needn't re-pin them.
    static let summaryFingerprints = [
        "swift-steward-17": "2706:dba1a2812282f379", "swift-steward-20": "1608:d36373ff0f431b65",
        "swift-steward-22": "12207:711f7ed0373919c6", "swift-steward-24": "8015:3f491566cab1a9b4",
        "swift-steward-26": "955:94188ea63aaeec63", "git-diff-parser-1": "331:cc79f51ccf4bbcf9",
        "git-diff-parser-2": "1709:822066d151275e32", "git-diff-parser-5": "9840:a04d7af473733094",
        "git-diff-parser-8": "5450:2f54c522cf74d8cd",
    ]

    static let serverURL = URL(string: "https://github.com")!

    /// `summary` with the footer naming Steward alone, not its release.
    static func versionless(_ summary: String) -> String {
        summary.replacingOccurrences(of: "<sub>Steward \(Release.version) · ", with: "<sub>Steward · ")
    }

    @Test("run as a workflow runs it, the fixture reports what git finds, writes the summary, and exits 0 or 1",
          arguments: pullRequests)
    func workflowRun(name: String) async throws {
        let pullRequest = try Merged(name)
        let expectation = try pullRequest.expectation()
        let run = try Self.workflowRun(of: pullRequest, payload: pullRequest.payload)
        let expected = expectation.report(repository: pullRequest.repository, pullRequest: pullRequest.number,
                                          head: pullRequest.head)
        #expect(run.outcome.status == expectation.status)
        #expect(run.outcome.output.isEmpty)
        #expect(run.report == expected)
        let runURL = Self.serverURL.appendingPathComponent("\(pullRequest.repository)/actions/runs/42")
        let summary = Summary(report: expected, serverURL: Self.serverURL, origin: .workflowRun(runURL),
                              unlinkedPaths: expectation.unlinkedPaths)
        #expect(run.jobSummary == summary.text)
        #expect(Fingerprint.of(Self.versionless(run.jobSummary)) == Self.summaryFingerprints[name])
        #expect(run.outcome.log.hasPrefix("""
            ::group::Context
            Pull request #\(pullRequest.number) in \(pullRequest.repository):\u{20}
            """))
        #expect(run.outcome.log.contains("::endgroup::\n::group::Rules\nSize: 1 finding\n"))
        // Without a token, the process posts nothing to these real pull
        // requests, and says so; then, last, it annotates the located
        // findings.
        let annotations = expected.findings.compactMap(Log.annotation(of:)).joined()
        #expect(run.outcome.log.hasSuffix(annotations))
        let log = run.outcome.log.dropLast(annotations.count)
        #expect(!log.contains("::error"))
        let warnings = log.split(separator: "\n").filter { $0.hasPrefix("::warning") }
        #expect(warnings.count == 1)
        #expect(warnings.first?.hasPrefix("::warning title=Steward::GITHUB_TOKEN isn't set") == true)
    }

    @Test("a dry run on a checkout of the head prints the same findings, makes no request, and exits alike",
          arguments: pullRequests)
    func dryRun(name: String) async throws {
        let pullRequest = try Merged(name)
        let expectation = try pullRequest.expectation()
        let clone = try TestRepository(cloning: pullRequest.mirror.path, options: ["--shared", "--no-checkout"])
        defer { clone.remove() }
        try clone.git(["switch", "--quiet", "--detach", pullRequest.head])
        let environment = ["GITHUB_REPOSITORY": pullRequest.repository]
        let reportURL = clone.root.appendingPathComponent("report.json")

        let recording = RecordingConsole()
        let status = await Runner.testing(
            ["--base", pullRequest.base, "--report", reportURL.path],
            environment: environment,
            directory: clone.path,
            recording: recording
        ).run(FixtureChecks.rules)
        let (output, log) = await recording.finishStreams()
        // A placeholder: number 0, sized from git, which matches GitHub here.
        let expected = expectation.report(repository: pullRequest.repository, pullRequest: 0, head: pullRequest.head)
        let summary = Summary(report: expected, serverURL: Self.serverURL, origin: .dryRun(isPlaceholder: true),
                              unlinkedPaths: expectation.unlinkedPaths)
        #expect(Int32(status.rawValue) == expectation.status)
        #expect(output == summary.text)
        #expect(try Self.report(at: reportURL) == expected)
        #expect(log.hasPrefix("Pull request #0 in \(pullRequest.repository): HEAD into \(pullRequest.base)\n"))
        #expect(!log.contains("::"))

        // The executable, whose hosts would go to the network: the same.
        let process = try FixtureDangerfile.run(
            ["--base", pullRequest.base],
            environment: TestRepository.runEnvironment(adding: environment),
            in: clone.url
        )
        #expect(process.status == expectation.status)
        #expect(process.output == summary.text)
        #expect(process.log == log)
    }

    @Test("a title that asks the last rule to throw fails a clean pull request, its error a row in the summary")
    func thrownRule() async throws {
        let pullRequest = try Merged("git-diff-parser-1")
        #expect(try pullRequest.expectation().status == 0)
        let title = try #require(pullRequest.payload.pullRequestField("title") as? String)
        let payload = pullRequest.payload.setting(fields: ["title": "\(title) \(FixtureChecks.throwMarker)"])
        let run = try Self.workflowRun(of: pullRequest, payload: payload)
        let expectation = try pullRequest.expectation(asksToThrow: true)
        #expect(run.outcome.status == 1)
        #expect(run.report == expectation.report(repository: pullRequest.repository, pullRequest: pullRequest.number,
                                                 head: pullRequest.head))
        #expect(run.jobSummary.contains("| :no_entry_sign: | \(FixtureExpectation.thrownRule) |"))
        #expect(run.outcome.log.contains("Fixture marker: 1 finding, 1 failing\n"))
    }

    /// Runs the fixture as Actions would on the pull request's merge
    /// commit, with `payload` as the event, in a new temporary directory.
    static func workflowRun(of pullRequest: Merged, payload: EventPayload) throws -> WorkflowRun {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = directory.appendingPathComponent("event.json")
        try payload.write(to: event)
        let summaryURL = directory.appendingPathComponent("summary.md")
        try Data().write(to: summaryURL)
        let outcome = try FixtureDangerfile.run(
            ["--report", "report.json"],
            environment: TestRepository.runEnvironment(adding: [
                "GITHUB_ACTIONS": "true",
                "GITHUB_EVENT_NAME": "pull_request",
                "GITHUB_EVENT_PATH": event.path,
                "GITHUB_WORKSPACE": pullRequest.mirror.path,
                "GITHUB_SHA": pullRequest.merge,
                "GITHUB_REPOSITORY": pullRequest.repository,
                "GITHUB_RUN_ID": "42",
                "GITHUB_STEP_SUMMARY": summaryURL.path,
            ]),
            in: directory
        )
        return WorkflowRun(
            outcome: outcome,
            report: try? report(at: directory.appendingPathComponent("report.json")),
            jobSummary: String(decoding: try Data(contentsOf: summaryURL), as: UTF8.self)
        )
    }

    static func report(at url: URL) throws -> Report {
        try JSONDecoder().decode(Report.self, from: Data(contentsOf: url))
    }
}
