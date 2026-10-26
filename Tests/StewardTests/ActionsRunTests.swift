import Foundation
import PullRequestHosting
@testable import Steward
import Testing

/// The context of the pull request whose checks run these tests, from the
/// environment, payload and checkout Actions set up for real.
///
/// Runs only in a `pull_request` workflow run. The macOS job checks out
/// with `fetch-depth: 0`, so its context is checked against git; the Linux
/// job's checkout has depth 1, so the context must refuse it.
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
}
