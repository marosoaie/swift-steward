import Foundation
@testable import GitHubAPI
import PullRequestHosting
@testable import Steward
import Testing

/// Posting the summary comment through `GitHubHost`, against `FakeGitHub`.
@Suite("The sticky summary comment")
struct StickyCommentTests {
    static let head = "4c95447a3d2f8e1b0c9d7e6f5a4b3c2d1e0f9a8b"
    static let bot = "github-actions[bot]"
    static let marker = "<!-- steward-summary -->\n"

    /// The pauses a posting made, which take no time.
    actor Pauses {
        private(set) var taken: [Duration] = []

        func take(_ duration: Duration) {
            taken.append(duration)
        }
    }

    /// What a posting did, and what it left.
    struct Posting {
        var outcome: StickyComment.Outcome
        var requests: [String]
        var comments: [FakeGitHub.Comment]
        var log: String
        var pauses: [Duration]
        var github: FakeGitHub
    }

    static let findings: [Finding] = [.failure("Broken", at: Location(path: "A.swift", line: 3)), .warning("Hm")]

    static func summary(_ findings: [Finding] = findings) -> Summary {
        SummaryBudgetTests.summary(findings)
    }

    /// Posts `summary` to `github`'s pull request as github-actions[bot],
    /// `perPage` comments a page, running `whilePausing` in each pause.
    static func post(
        _ summary: Summary = summary(),
        to github: FakeGitHub,
        perPage: Int = 100,
        elsewhere: Summary.Elsewhere = .jobSummary,
        whilePausing: @escaping @Sendable () async -> Void = {}
    ) async throws -> Posting {
        let recording = RecordingConsole()
        let pauses = Pauses()
        let host = GitHubHost(
            owner: FakeGitHub.owner,
            repository: FakeGitHub.repository,
            token: FakeGitHub.token,
            apiURL: URL(string: "https://api.github.com")!,
            summaryAuthor: bot,
            commentsPerPage: perPage,
            transport: github
        )
        let sticky = StickyComment(
            host: host,
            pullRequest: 21,
            headCommit: head,
            log: Log(mode: .actions, console: recording.console, makeToken: { "T0K3N" }),
            sleep: {
                await pauses.take($0)
                await whilePausing()
            }
        )
        let outcome = try await sticky.post(summary, elsewhere: elsewhere)
        let (_, log) = await recording.finishStreams()
        return Posting(
            outcome: outcome,
            requests: await github.requests.map(\.description),
            comments: await github.comments,
            log: log,
            pauses: await pauses.taken,
            github: github
        )
    }

    static let list = "GET /repos/marosoaie/swift-steward/issues/21/comments?per_page=100&page=1"
    static let read = "GET /repos/marosoaie/swift-steward/pulls/21"
    static let create = "POST /repos/marosoaie/swift-steward/issues/21/comments"

    static func edit(_ id: Int64) -> String {
        "PATCH /repos/marosoaie/swift-steward/issues/comments/\(id)"
    }

    static func delete(_ id: Int64) -> String {
        "DELETE /repos/marosoaie/swift-steward/issues/comments/\(id)"
    }

    static var posted: String {
        marker + summary().text(fitting: 65_511, elsewhere: .jobSummary)
    }

    @Test("with no summary comment yet, findings create one, marked, after re-reading the pull request")
    func create() async throws {
        let posting = try await Self.post(to: FakeGitHub(head: Self.head))
        #expect(posting.requests == [Self.list, Self.read, Self.create])
        #expect(posting.comments == [FakeGitHub.Comment(id: 1_001, body: Self.posted, login: Self.bot)])
        guard case .created(let comment) = posting.outcome else { Issue.record("\(posting.outcome)"); return }
        #expect(comment.id.rawValue == 1_001)
        #expect(posting.log == """
            Posted the summary comment: https://github.com/marosoaie/swift-steward/pull/21#issuecomment-1001

            """)
    }

    @Test("a clean pull request without a summary comment gets none, after one request")
    func cleanWithoutComment() async throws {
        let posting = try await Self.post(Self.summary([]), to: FakeGitHub(head: Self.head))
        #expect(posting.requests == [Self.list])
        #expect(posting.comments.isEmpty)
        guard case .nothingToPost = posting.outcome else { Issue.record("\(posting.outcome)"); return }
        #expect(posting.log.contains("nothing to post"))
    }

    @Test("an existing summary comment is updated in place, to the findings or, when clean, to all clear",
          arguments: [false, true])
    func update(isClean: Bool) async throws {
        let github = FakeGitHub(head: Self.head)
        let id = await github.addComment(Self.marker + "Old findings", by: Self.bot)
        let summary = Self.summary(isClean ? [] : Self.findings)
        let posting = try await Self.post(summary, to: github)
        #expect(posting.requests == [Self.list, Self.read, Self.edit(id)])
        let text = Self.marker + summary.text
        #expect(posting.comments == [FakeGitHub.Comment(id: id, body: text, login: Self.bot)])
        #expect(text.contains("**No findings** on 4c95447") == isClean)
        guard case .updated(let comment, deletedDuplicates: 0) = posting.outcome else {
            Issue.record("\(posting.outcome)")
            return
        }
        #expect(comment.id.rawValue == id)
    }

    @Test("duplicates from racing runs: the oldest is updated, then the others deleted")
    func duplicates() async throws {
        let github = FakeGitHub(head: Self.head)
        let ids = [
            await github.addComment(Self.marker + "First", by: Self.bot),
            await github.addComment("LGTM", by: "reviewer"),
            await github.addComment(Self.marker + "Second", by: Self.bot),
            await github.addComment(Self.marker + "Third", by: Self.bot),
        ]
        let posting = try await Self.post(to: github)
        #expect(posting.requests == [Self.list, Self.read, Self.edit(ids[0]), Self.delete(ids[2]), Self.delete(ids[3])])
        #expect(posting.comments.map(\.id) == [ids[0], ids[1]])
        #expect(posting.comments.first?.body == Self.posted)
        #expect(posting.log.contains("#issuecomment-\(ids[0]), and deleted 2 duplicates"))
    }

    @Test("comments by anyone else that carry the marker are left alone, and the run posts its own")
    func otherAuthors() async throws {
        let github = FakeGitHub(head: Self.head)
        let others = [
            await github.addComment(Self.marker + "Copied by hand", by: "marosoaie"),
            await github.addComment(Self.marker + "Another bot", by: "renovate[bot]"),
        ]
        let posting = try await Self.post(to: github)
        #expect(posting.requests == [Self.list, Self.read, Self.create])
        #expect(posting.comments.map(\.id) == others + [1_003])
        #expect(posting.comments.prefix(2).map(\.body) == [Self.marker + "Copied by hand", Self.marker + "Another bot"])
    }

    @Test("the summary comment is found pages in, and only it is updated")
    func pagination() async throws {
        let github = FakeGitHub(head: Self.head)
        await (1...5).asyncForEach { await github.addComment("Comment \($0)", by: "reviewer") }
        let id = await github.addComment(Self.marker + "Old", by: Self.bot)
        await github.addComment("Comment 7", by: "reviewer")
        let posting = try await Self.post(to: github, perPage: 2)
        #expect(posting.requests == (1...4).map {
            "GET /repos/marosoaie/swift-steward/issues/21/comments?per_page=2&page=\($0)"
        } + [Self.read, Self.edit(id)])
        #expect(posting.comments.count == 7)
        #expect(posting.comments.filter { $0.body == Self.posted }.map(\.id) == [id])
    }

    @Test("a run whose commit is no longer the head writes nothing, and says why", arguments: [false, true])
    func stale(hasComment: Bool) async throws {
        let github = FakeGitHub(head: String(repeating: "b", count: 40))
        if hasComment {
            await github.addComment(Self.marker + "Newer run's", by: Self.bot)
        }
        let posting = try await Self.post(to: github)
        #expect(posting.requests == [Self.list, Self.read])
        #expect(posting.comments.map(\.body) == (hasComment ? [Self.marker + "Newer run's"] : []))
        guard case .stale(let head) = posting.outcome else { Issue.record("\(posting.outcome)"); return }
        #expect(head == String(repeating: "b", count: 40))
        #expect(posting.log.contains("so this run posts nothing"))
        #expect(!posting.log.contains("::warning"))
    }

    @Test("a head reported in capitals is still the same commit")
    func headCase() async throws {
        let posting = try await Self.post(to: FakeGitHub(head: Self.head.uppercased()))
        #expect(posting.requests.last == Self.create)
    }

    @Test("a summary comment deleted after it was found is posted anew, and the duplicates still go")
    func deletedSinceListed() async throws {
        let github = FakeGitHub(head: Self.head)
        let ids = [
            await github.addComment(Self.marker + "Deleted by hand", by: Self.bot),
            await github.addComment(Self.marker + "Duplicate", by: Self.bot),
        ]
        await github.fail("issues/update-comment", with: .status(404, message: "Not Found"))
        let posting = try await Self.post(to: github)
        #expect(posting.requests == [Self.list, Self.read, Self.edit(ids[0]), Self.create, Self.delete(ids[1])])
        #expect(posting.comments.map(\.body) == [Self.marker + "Deleted by hand", Self.posted])
        guard case .created = posting.outcome else { Issue.record("\(posting.outcome)"); return }
        #expect(posting.log.contains("is gone since it was found, so Steward posts a new one"))
        #expect(!posting.log.contains("::warning"))
    }

    @Test("a summary over GitHub's limit is cut to fit with the marker, and GitHub's fake takes it")
    func budget() async throws {
        let findings = (1...2_000).map { (line: Int) in
            Finding.warning("Warning number \(line), with some words", at: Location(path: "A.swift", line: line))
        }
        let posting = try await Self.post(Self.summary(findings), to: FakeGitHub(head: Self.head), elsewhere: .log)
        let body = try #require(posting.comments.first?.body)
        #expect(body.utf8.count <= 65_536)
        #expect(body.utf8.count > 65_536 - 300)
        #expect(body.hasPrefix(Self.marker + "**2000 warnings** on 4c95447"))
        #expect(body.contains(/more findings\. Everything is in the log of \[the workflow run\]/))
    }
}
