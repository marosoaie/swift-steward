import Foundation
@testable import GitHubAPI
import OpenAPIRuntime
import OpenAPIURLSession
import PullRequestHosting
import Testing

/// GitHubHost's write path against a real pull request: Phase 3's "the
/// client creates, updates, and deletes a comment on a sandbox PR". Opt-in
/// through `STEWARD_LIVE_GITHUB_WRITE_TESTS=1` (see `LiveSandbox`), and
/// fenced: `SandboxOnlyMiddleware` refuses any request outside the sandbox
/// pull request before it leaves the process, and the comment carries a
/// marker unique to the run, so no other comment can match it.
@Suite(
    "GitHubHost creates, updates, and deletes a comment on the sandbox pull request (opt-in, writes)",
    .enabled(if: LiveSandbox.isRequested)
)
struct LiveSandboxTests {
    let apiURL = URL(string: "https://api.github.com")!

    @Test("a summary comment's life on a real pull request, each step checked against the raw comment list")
    func roundTrip() async throws {
        let sandbox = try #require(
            LiveSandbox.current,
            "set STEWARD_SANDBOX_REPOSITORY=owner/name, STEWARD_SANDBOX_PULL_REQUEST, and GITHUB_TOKEN"
        )
        let marker = SummaryMarker(line: "<!-- steward-live-test \(UUID().uuidString) -->")
        // Two a page, so finding the comment pages through any others.
        let host = GitHubHost(
            owner: sandbox.owner,
            repository: sandbox.repository,
            token: sandbox.token,
            apiURL: apiURL,
            marker: marker,
            commentsPerPage: 2,
            transport: URLSessionTransport(),
            middlewares: [SandboxOnlyMiddleware(
                owner: sandbox.owner,
                repository: sandbox.repository,
                pullRequest: sandbox.pullRequest
            )]
        )

        let pull = try await host.pullRequest(number: sandbox.pullRequest)
        #expect(pull.number == sandbox.pullRequest)
        #expect(pull.base.repository == "\(sandbox.owner)/\(sandbox.repository)")
        #expect(try await host.summaryComments(onPullRequest: sandbox.pullRequest).isEmpty)

        let first = "Steward's live test (step 3.5): created. It deletes this comment within seconds."
        let created = try await host.createSummaryComment(onPullRequest: sandbox.pullRequest, body: first)
        do {
            #expect(created.body == first)
            #expect(try await rawText(of: created.id, in: sandbox) == marker.marking(first))
            #expect(try await host.summaryComments(onPullRequest: sandbox.pullRequest) == [created])

            let second = "Steward's live test (step 3.5): updated. It deletes this comment within seconds."
            let updated = try await host.updateSummaryComment(created.id, body: second)
            #expect(updated.id == created.id)
            #expect(updated.body == second)
            #expect(try await rawText(of: created.id, in: sandbox) == marker.marking(second))
            #expect(try await host.summaryComments(onPullRequest: sandbox.pullRequest) == [updated])
        } catch {
            try? await host.deleteSummaryComment(created.id)
            throw error
        }

        try await host.deleteSummaryComment(created.id)
        #expect(try await rawText(of: created.id, in: sandbox) == nil)
        #expect(try await host.summaryComments(onPullRequest: sandbox.pullRequest).isEmpty)
        // GitHub's 404s for a comment that's gone, live.
        try await host.deleteSummaryComment(created.id)
        let error = await #expect(throws: PullRequestHostError.self) {
            _ = try await host.updateSummaryComment(created.id, body: "gone")
        }
        #expect(error?.kind == .notFound)
    }

    /// The comment's raw text in the pull request's comment list, read with
    /// the generated client and without the host: the oracle.
    func rawText(of id: SummaryComment.ID, in sandbox: LiveSandbox) async throws -> String? {
        let comments = try await Client(
            serverURL: apiURL,
            transport: URLSessionTransport(),
            middlewares: [ReadOnlyMiddleware(), GitHubHeadersMiddleware(token: sandbox.token)]
        )
        .issuesListComments(
            path: .init(owner: sandbox.owner, repo: sandbox.repository, issueNumber: sandbox.pullRequest),
            query: .init(perPage: 100)
        )
        .ok.body.json
        try #require(comments.count < 100, "the oracle reads one page of 100")
        return comments.first { $0.id == id.rawValue }?.body
    }
}
