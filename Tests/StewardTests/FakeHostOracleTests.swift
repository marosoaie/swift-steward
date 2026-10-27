import Foundation
@testable import Steward
import StewardTesting
import Testing

/// StewardTesting's `FakePullRequestHost` against `GitHubHost` over the
/// simulated REST API: the same rules on the same pull request, once as
/// a CI run and once as a fixture run, must send the same requests and
/// leave the same comments, summary, status, and log.
@Suite("The fake host against the simulated GitHub")
struct FakeHostOracleTests {
    /// What the pull request looks like when the run starts, and what the
    /// rules find.
    enum Scenario: String, CaseIterable, Sendable {
        case firstRun = "findings, no summary comment yet"
        case laterRun = "findings, a summary comment and someone else's"
        case allClear = "no findings, a summary comment"
        case cleanWithoutComment = "no findings, no summary comment"
        case duplicates = "findings, three summary comments from runs that raced"
        case staleHead = "findings, a summary comment, and a head that moved on"
        case cutSummary = "more findings than a comment holds"
        case justOverTheLimit = "a summary 10 bytes longer than a comment holds"

        /// The rules; `padding` lengthens the one long finding of
        /// `justOverTheLimit`.
        func rules(padding: Int = 0) -> [Rule] {
            switch self {
            case .firstRun, .laterRun, .duplicates, .staleHead: RunnerPostingTests.failing
            case .allClear, .cleanWithoutComment: []
            case .cutSummary: RunnerPostingTests.warnings(600)
            case .justOverTheLimit:
                [Rule("Long") { _ in [.warning(String(repeating: "x", count: 60_000 + padding))] }]
            }
        }

        /// The summary comments already posted, oldest first.
        var summaries: [String] {
            switch self {
            case .firstRun, .cleanWithoutComment, .cutSummary, .justOverTheLimit: []
            case .laterRun, .allClear, .staleHead: ["**1 failure** on 0000000"]
            case .duplicates: ["**1 failure** on 0000000", "**1 failure** on 1111111", "**2 failures** on 1111111"]
            }
        }
    }

    static let pushed = String(repeating: "f", count: 40)
    /// What a comment on GitHub holds once the marker line is in: the
    /// number GitHub's error states, not the one `GitHubHost` computes.
    static let commentLimit = 65_536 - RunnerPostingTests.marker.utf8.count

    @Test("a fixture run sends the fake host what a CI run sends GitHub", arguments: Scenario.allCases)
    func sameRun(scenario: Scenario) async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        var environment = try RunnerTests.environment(for: fixture)
        // A fixture run has no workflow run for its summary to link to.
        environment["GITHUB_RUN_ID"] = nil
        let summaries = scenario.summaries
        let context = try await Context.actions(environment: environment)
        let rules = scenario == .justOverTheLimit
            ? scenario.rules(padding: try await Self.padding(toReach: Self.commentLimit + 10, in: context))
            : scenario.rules()
        let github = FakeGitHub(
            head: scenario == .staleHead ? Self.pushed : fixture.head,
            comments: summaries.enumerated().map { offset, body in
                FakeGitHub.Comment(id: Int64(offset) + 1, body: RunnerPostingTests.marker + body,
                                   login: "github-actions[bot]")
            } + [FakeGitHub.Comment(id: 500, body: "Looks good to me.", login: "octocat")]
        )
        let real = try await RunnerTests.run(rules, on: fixture, environment: environment, github: github)

        let host = FakePullRequestHost(pullRequest: context.pullRequest, comments: summaries)
        if scenario == .staleHead {
            await host.push(Self.pushed)
        }
        let fake = await FixtureRun(running: rules, in: context, postingTo: host)

        let gitHubRequests = await github.requests
        Self.expectExercised(scenario, gitHubRequests.map(\.method), real.jobSummary ?? "", await github.comments)
        #expect(await host.requests == Self.hostRequests(for: gitHubRequests, on: github.number))
        #expect(fake.exitStatus == real.status.rawValue)
        #expect(fake.summary == real.jobSummary)
        #expect(Self.withoutNewIDs(fake.log, above: summaries.count)
            == Self.withoutNewIDs(real.log, above: summaries.count))
        let realComments = real.comments.compactMap { comment in
            comment.body.hasPrefix(RunnerPostingTests.marker)
                ? Self.Comment(comment.id, String(comment.body.dropFirst(RunnerPostingTests.marker.count)),
                               above: summaries.count)
                : nil
        }
        let fakeComments = await host.comments.map { Self.Comment($0.id.rawValue, $0.body, above: summaries.count) }
        #expect(fakeComments == realComments)
    }

    /// Expects the CI run to have done what `scenario` is there to check,
    /// so a scenario that stops exercising its case fails instead of
    /// passing on both sides.
    static func expectExercised(
        _ scenario: Scenario,
        _ methods: [String],
        _ jobSummary: String,
        _ comments: [FakeGitHub.Comment]
    ) {
        let writes = methods.filter { $0 != "GET" }
        switch scenario {
        case .firstRun: #expect(writes == ["POST"])
        case .laterRun: #expect(writes == ["PATCH"])
        case .allClear:
            #expect(writes == ["PATCH"])
            #expect(comments.first?.body.hasPrefix(RunnerPostingTests.marker + "**No findings**") == true)
        case .cleanWithoutComment: #expect(methods == ["GET"])
        case .duplicates: #expect(writes == ["PATCH", "DELETE", "DELETE"])
        case .staleHead: #expect(writes.isEmpty && methods.count == 2)
        case .cutSummary, .justOverTheLimit:
            #expect(writes == ["POST"])
            let comment = comments.first { $0.login == "github-actions[bot]" }
                .map { $0.body.dropFirst(RunnerPostingTests.marker.count) }
            #expect((comment?.utf8.count ?? .max) < jobSummary.utf8.count)
            if scenario == .justOverTheLimit {
                #expect(jobSummary.utf8.count == commentLimit + 10)
            }
        }
    }

    /// How many more bytes `justOverTheLimit`'s finding needs for its
    /// summary to be `size` bytes long, measured on a host that takes any
    /// size.
    static func padding(toReach size: Int, in context: Context) async throws -> Int {
        let host = FakePullRequestHost(pullRequest: context.pullRequest, maximumSummarySize: .max)
        let unpadded = await FixtureRun(running: Scenario.justOverTheLimit.rules(), in: context, postingTo: host)
        let padding = size - unpadded.summary.utf8.count
        try #require(padding >= 0, "the unpadded summary has \(unpadded.summary.utf8.count) bytes")
        return padding
    }

    /// A summary comment, with the id only of one posted before the run:
    /// the two hosts number new comments differently.
    struct Comment: Equatable {
        var id: Int64?
        var body: String

        init(_ id: Int64, _ body: String, above posted: Int) {
            self.id = id <= posted ? id : nil
            self.body = body
        }
    }

    /// The requests `GitHubHost` sent, as the `PullRequestHost` calls they
    /// carry out, with the marker line taken off the comments' text.
    static func hostRequests(for requests: [FakeGitHub.Request], on number: Int) -> [FakePullRequestHost.Request] {
        let repository = "/repos/\(FakeGitHub.owner)/\(FakeGitHub.repository)/"
        let comment = "issues/comments/"
        return requests.compactMap { request in
            let path = request.path.prefix { $0 != "?" }
            guard path.hasPrefix(repository) else {
                Issue.record("\(request) isn't in the repository")
                return nil
            }
            let route = String(path.dropFirst(repository.count))
            let body = String((request.text ?? "").dropFirst(RunnerPostingTests.marker.count))
            let id = Int64(route.dropFirst(comment.count)).map { SummaryComment.ID(rawValue: $0) }
            switch (request.method, route) {
            case ("GET", "pulls/\(number)"): return .pullRequest(number: number)
            case ("GET", "issues/\(number)/comments"): return .summaryComments(pullRequest: number)
            case ("POST", "issues/\(number)/comments"): return .createSummaryComment(pullRequest: number, body: body)
            case ("PATCH", _) where id != nil: return id.map { .updateSummaryComment($0, body: body) }
            case ("DELETE", _) where id != nil: return id.map { .deleteSummaryComment($0) }
            default:
                Issue.record("\(request) isn't a request a PullRequestHost call sends")
                return nil
            }
        }
    }

    /// `log` with the ids of comments posted during the run left out of
    /// their links.
    static func withoutNewIDs(_ log: String, above posted: Int) -> String {
        log.replacing(/#issuecomment-(\d+)/) { match in
            (Int(match.output.1) ?? 0) <= posted ? match.output.0 : "#issuecomment-new"
        }
    }
}
