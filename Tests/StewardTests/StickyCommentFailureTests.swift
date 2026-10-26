import Foundation
@testable import GitHubAPI
import PullRequestHosting
@testable import Steward
import Testing

/// Failing to post the summary comment: what's retried, and what's said.
@Suite("Posting the sticky summary comment when GitHub fails")
struct StickyCommentFailureTests {
    /// A failed request, how often it fails, and what posting must do.
    struct FailureCase: Sendable, CustomTestStringConvertible {
        let name: String
        let operation: String
        let failures: [FakeGitHub.Failure]
        /// The pauses before retries; empty for none.
        let pauses: [Duration]
        let posts: Bool
        /// What the warning must say, when there is one.
        var warning: String?

        var testDescription: String {
            name
        }
    }

    static let failureCases = [
        FailureCase(
            name: "forbidden",
            operation: "issues/create-comment",
            failures: [.status(403, message: "Resource not accessible by integration")],
            pauses: [],
            posts: false,
            warning: """
                Couldn't post the summary comment: issues/create-comment failed (forbidden): HTTP 403: Resource not \
                accessible by integration. The token needs permission to comment: give the job `pull-requests: write`
                """
        ),
        FailureCase(
            name: "unauthorized",
            operation: "issues/list-comments",
            failures: [.status(401, message: "Bad credentials")],
            pauses: [],
            posts: false,
            warning: "HTTP 401: Bad credentials. Check the token in GITHUB_TOKEN. The findings are in this run's log"
        ),
        FailureCase(
            name: "rejected",
            operation: "issues/create-comment",
            failures: [.status(422, message: "Validation Failed")],
            pauses: [],
            posts: false,
            warning: "failed (rejected): HTTP 422: Validation Failed. The findings"
        ),
        FailureCase(
            name: "server error, once",
            operation: "issues/create-comment",
            failures: [.status(502, message: "Bad Gateway")],
            pauses: [.seconds(2)],
            posts: true
        ),
        FailureCase(
            name: "server error, twice",
            operation: "pulls/get",
            failures: [.status(500, message: "Server Error"), .status(503, message: "Unavailable")],
            pauses: [.seconds(2)],
            posts: false,
            warning: "pulls/get failed (serverError): HTTP 503: Unavailable."
        ),
        FailureCase(name: "network, once", operation: "issues/list-comments", failures: [.network],
                    pauses: [.seconds(2)], posts: true),
        FailureCase(
            name: "rate limit with a retry-after",
            operation: "issues/create-comment",
            failures: [.status(429, message: "Slow down", headers: ["retry-after": "7"])],
            pauses: [.seconds(7)],
            posts: true
        ),
        FailureCase(
            name: "rate limit without a wait",
            operation: "issues/create-comment",
            failures: [.status(403, message: "You have exceeded a secondary rate limit")],
            pauses: [.seconds(60)],
            posts: true
        ),
        FailureCase(
            name: "rate limit asking for too long",
            operation: "issues/create-comment",
            failures: [.status(403, message: "Abuse", headers: ["retry-after": "120"])],
            pauses: [],
            posts: false,
            warning: "GitHub asks to wait 120 seconds before trying again, longer than Steward waits."
        ),
        FailureCase(
            name: "rate limit used up",
            operation: "issues/list-comments",
            failures: [.status(403, message: "API rate limit exceeded", headers: [
                "x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(Int(Date().timeIntervalSince1970) + 3_000)",
            ])],
            pauses: [],
            posts: false,
            warning: "longer than Steward waits."
        ),
        FailureCase(name: "malformed", operation: "pulls/get", failures: [.malformed], pauses: [], posts: false,
                    warning: "pulls/get failed (malformedResponse)"),
    ]

    @Test("each failure warns with what to do, and only waiting's are retried, once", arguments: failureCases)
    func failures(_ failure: FailureCase) async throws {
        let github = FakeGitHub(head: StickyCommentTests.head)
        await failure.failures.asyncForEach { await github.fail(failure.operation, with: $0) }
        let posting = try await StickyCommentTests.post(to: github)
        #expect(posting.pauses == failure.pauses)
        #expect(posting.comments.map(\.body) == (failure.posts ? [StickyCommentTests.posted] : []))
        let retried = posting.requests.count - Set(posting.requests).count
        #expect(retried == failure.pauses.count)
        if failure.posts {
            #expect(posting.log.contains("Trying again in"))
            guard case .created = posting.outcome else { Issue.record("\(posting.outcome)"); return }
        } else {
            guard case .failed = posting.outcome else { Issue.record("\(posting.outcome)"); return }
            let warnings = posting.log.split(separator: "\n").filter { $0.hasPrefix("::warning title=Steward::") }
            let warning = try #require(warnings.first)
            #expect(warnings.count == 1)
            #expect(warning.contains(try #require(failure.warning)), "\(warning)")
            #expect(warning.hasSuffix("The findings are in this run's log and job summary."))
        }
    }

    @Test("a failure's warning says where the findings are instead", arguments: [
        (Summary.Elsewhere.jobSummary, "log and job summary."),
        (.reportArtifact, "log and report."),
        (.log, "log."),
    ])
    func warningElsewhere(elsewhere: Summary.Elsewhere, place: String) {
        let error = PullRequestHostError(kind: .rejected, operation: "issues/create-comment")
        #expect(StickyComment.warning(for: error, elsewhere: elsewhere) == """
            Couldn't post the summary comment: issues/create-comment failed (rejected). \
            The findings are in this run's \(place)
            """)
    }

    @Test("a duplicate that can't be deleted fails the posting, after the update went through")
    func failedDelete() async throws {
        let github = FakeGitHub(head: StickyCommentTests.head)
        let ids = [
            await github.addComment(StickyCommentTests.marker + "First", by: StickyCommentTests.bot),
            await github.addComment(StickyCommentTests.marker + "Second", by: StickyCommentTests.bot),
        ]
        await github.fail("issues/delete-comment", with: .status(403, message: "Forbidden"))
        let posting = try await StickyCommentTests.post(to: github)
        #expect(posting.comments.map(\.id) == ids)
        #expect(posting.comments.first?.body == StickyCommentTests.posted)
        guard case .failed = posting.outcome else { Issue.record("\(posting.outcome)"); return }
    }

    @Test("a creation whose response was lost is retried, and the duplicate it leaves goes on the next run")
    func lostResponse() async throws {
        let github = FakeGitHub(head: StickyCommentTests.head)
        await github.fail("issues/create-comment", with: .lostResponse)
        let first = try await StickyCommentTests.post(to: github)
        #expect(first.comments.count == 2)
        let second = try await StickyCommentTests.post(to: github)
        #expect(second.comments.map(\.id) == [1_001])
        #expect(second.comments.first?.body == StickyCommentTests.posted)
    }

    @Test("a run cancelled during a pause stops posting with a CancellationError")
    func cancelled() async throws {
        let github = FakeGitHub(head: StickyCommentTests.head)
        await github.fail("issues/list-comments", with: .status(502, message: "Bad Gateway"))
        let host = GitHubHost(
            owner: FakeGitHub.owner,
            repository: FakeGitHub.repository,
            token: FakeGitHub.token,
            apiURL: URL(string: "https://api.github.com")!,
            summaryAuthor: StickyCommentTests.bot,
            transport: github
        )
        let sticky = StickyComment(
            host: host,
            pullRequest: 21,
            headCommit: StickyCommentTests.head,
            log: Log(mode: .actions, console: RecordingConsole().console),
            sleep: { _ in throw CancellationError() }
        )
        await #expect(throws: CancellationError.self) {
            _ = try await sticky.post(StickyCommentTests.summary(), elsewhere: .jobSummary)
        }
        #expect(await github.comments.isEmpty)
    }

    @Test("only rate limits, server errors, and lost connections are worth a pause, and none past a minute")
    func pauses() {
        let error = { (kind: PullRequestHostError.Kind, wait: Duration?) in
            StickyComment.pause(before: PullRequestHostError(kind: kind, operation: "x", retryAfter: wait))
        }
        #expect(error(.rateLimited, nil) == .seconds(60))
        #expect(error(.rateLimited, .seconds(60)) == .seconds(60))
        #expect(error(.rateLimited, .milliseconds(60_001)) == nil)
        #expect(error(.serverError, nil) == .seconds(2))
        #expect(error(.network, .seconds(5)) == .seconds(5))
        let never: [PullRequestHostError.Kind] = [
            .notFound, .unauthorized, .forbidden, .rejected, .unexpectedStatus, .malformedResponse,
        ]
        #expect(never.allSatisfy { error($0, .seconds(1)) == nil })
    }
}
