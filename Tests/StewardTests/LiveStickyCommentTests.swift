import Foundation
@testable import GitHubAPI
import PullRequestHosting
@testable import Steward
import Testing

/// StickyComment against a real pull request: step 4.4's live check.
/// Opt-in through `STEWARD_LIVE_GITHUB_WRITE_TESTS=1` (see
/// `LivePullRequest`), and fenced: `OwnCommentsMiddleware` refuses any
/// request outside the pull request, and any edit or deletion of a comment
/// the test didn't create, before it leaves the process. The comments carry
/// a marker unique to the run, so no other comment can match it.
@Suite(
    "The summary comment's life on a real pull request (opt-in, writes)",
    .enabled(if: LivePullRequest.isRequested)
)
struct LiveStickyCommentTests {
    static let apiURL = URL(string: "https://api.github.com")!

    /// The test's view of the pull request: its host, fenced, and the
    /// comment list read without the host.
    struct Sandbox {
        let live: LivePullRequest
        let marker: SummaryMarker
        let fence: OwnCommentsMiddleware
        let host: GitHubHost
        let head: String

        /// A summary of `findings` on the pull request's head.
        func summary(_ findings: [Finding]) -> Summary {
            Summary(
                report: Report(
                    repository: live.repository.description,
                    pullRequest: live.number,
                    headCommit: head,
                    findings: findings,
                    generator: "Steward's live test (step 4.4)"
                ),
                serverURL: URL(string: "https://github.com")!,
                origin: .workflowRun(nil)
            )
        }

        func post(_ summary: Summary, headCommit: String? = nil) async throws -> StickyComment.Outcome {
            let comment = StickyComment(
                host: host,
                pullRequest: live.number,
                headCommit: headCommit ?? head,
                log: Log(mode: .actions, console: RecordingConsole().console),
                sleep: { try await Task.sleep(for: $0) }
            )
            return try await comment.post(summary, elsewhere: .log)
        }

        /// The raw text of each comment that carries the run's marker, by
        /// id, read with the generated client: the oracle.
        func marked() async throws -> [Int64: String] {
            let comments = try await Client(
                serverURL: LiveStickyCommentTests.apiURL,
                transport: GitHubHost.uncachedTransport(),
                middlewares: [fence, GitHubHeadersMiddleware(token: live.token)]
            )
            .issuesListComments(
                path: .init(owner: live.repository.owner, repo: live.repository.name, issueNumber: live.number),
                query: .init(perPage: 100)
            )
            .ok.body.json
            try #require(comments.count < 100, "the oracle reads one page of 100")
            return Dictionary(uniqueKeysWithValues: comments.compactMap { comment in
                comment.body.flatMap { $0.hasPrefix(marker.line) ? (comment.id, $0) : nil }
            })
        }
    }

    @Test("runs post, update, collapse a duplicate, fit an oversize summary, skip a stale run, and go all clear")
    func life() async throws {
        let live = try #require(
            LivePullRequest.current,
            "set STEWARD_SANDBOX_REPOSITORY=owner/name, STEWARD_SANDBOX_PULL_REQUEST, and GITHUB_TOKEN"
        )
        let marker = SummaryMarker(line: "<!-- steward-live-test \(UUID().uuidString) -->")
        let fence = OwnCommentsMiddleware(repository: live.repository, pullRequest: live.number)
        // Two a page, so finding the comments pages through any others.
        let host = GitHubHost(
            owner: live.repository.owner,
            repository: live.repository.name,
            token: live.token,
            apiURL: Self.apiURL,
            summaryAuthor: live.summaryAuthor,
            marker: marker,
            commentsPerPage: 2,
            transport: GitHubHost.uncachedTransport(),
            middlewares: [fence]
        )
        let head = try await host.pullRequest(number: live.number).head.commit
        let sandbox = Sandbox(live: live, marker: marker, fence: fence, host: host, head: head)
        do {
            try await Self.life(in: sandbox)
        } catch {
            try? await Self.cleanUp(sandbox)
            throw error
        }
        try await Self.cleanUp(sandbox)
        #expect(try await sandbox.marked().isEmpty)
    }

    static func life(in sandbox: Sandbox) async throws {
        let clean = sandbox.summary([])
        guard case .nothingToPost = try await sandbox.post(clean) else {
            Issue.record("a clean pull request without a summary comment got one")
            return
        }
        #expect(try await sandbox.marked().isEmpty)

        let first = sandbox.summary([
            .failure("Live test (step 4.4): created. It deletes this comment within a minute.",
                     at: Location(path: "Package.swift", line: 1)),
            .warning("A warning, with `code` and a | pipe."),
        ])
        guard case .created(let comment) = try await sandbox.post(first) else {
            Issue.record("the first run didn't create the comment")
            return
        }
        let id = comment.id.rawValue
        #expect(try await sandbox.marked() == [id: sandbox.marker.marking(first.text)])

        let second = sandbox.summary([.message("Live test (step 4.4): updated.")])
        let updated = try await sandbox.post(second)
        #expect(updated.comment?.id == comment.id && updated.deletedDuplicates == 0)
        #expect(try await sandbox.marked() == [id: sandbox.marker.marking(second.text)])

        // What a race between two runs leaves: a newer duplicate.
        let duplicate = try await sandbox.host.createSummaryComment(onPullRequest: sandbox.live.number, body: "Racer")
        #expect(try await sandbox.marked().keys.sorted() == [id, duplicate.id.rawValue])
        let third = sandbox.summary([.message("Live test (step 4.4): the duplicate is gone.")])
        let collapsed = try await sandbox.post(third)
        #expect(collapsed.comment?.id == comment.id && collapsed.deletedDuplicates == 1)
        #expect(try await sandbox.marked() == [id: sandbox.marker.marking(third.text)])

        // Two-byte letters, so a budget in characters would overrun bytes.
        let oversize = sandbox.summary((1...2_000).map { (line: Int) in
            .warning("Wärning \(line): über the limit, so it's cut.", at: Location(path: "a.swift", line: line))
        })
        #expect(oversize.text.utf8.count > 2 * 65_536)
        let cut = sandbox.marker.marking(oversize.text(fitting: sandbox.host.maximumSummarySize, elsewhere: .log))
        #expect(cut.utf8.count <= 65_536 && cut.utf8.count > 65_536 - 400)
        #expect(try await sandbox.post(oversize).comment?.id == comment.id)
        #expect(try await sandbox.marked() == [id: cut])

        let stale = String(repeating: "0", count: 40)
        guard case .stale(let actual) = try await sandbox.post(second, headCommit: stale) else {
            Issue.record("a run for another commit wrote")
            return
        }
        #expect(actual == sandbox.head)
        #expect(try await sandbox.marked() == [id: cut])

        #expect(try await sandbox.post(clean).comment?.id == comment.id)
        let allClear = try #require(try await sandbox.marked()[id])
        #expect(allClear == sandbox.marker.marking(clean.text))
        #expect(allClear.contains("**No findings** on \(sandbox.head.prefix(7))"))
    }

    /// Deletes every comment the test created, by the ids its fence
    /// recorded, so that cleaning up relies on neither the listing nor the
    /// author filter the test checks. Deleting one already gone succeeds.
    static func cleanUp(_ sandbox: Sandbox) async throws {
        try await sandbox.fence.created.ids.sorted().asyncForEach {
            try await sandbox.host.deleteSummaryComment(SummaryComment.ID(rawValue: $0))
        }
    }
}

extension StickyComment.Outcome {
    /// The comment created or updated, if any.
    var comment: SummaryComment? {
        switch self {
        case .created(let comment), .updated(let comment, _): comment
        case .nothingToPost, .stale, .failed: nil
        }
    }

    /// How many duplicates an update deleted, or nil for any other outcome.
    var deletedDuplicates: Int? {
        guard case .updated(_, let deleted) = self else { return nil }
        return deleted
    }
}
