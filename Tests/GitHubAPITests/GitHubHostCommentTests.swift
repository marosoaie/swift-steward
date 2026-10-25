import Foundation
@testable import GitHubAPI
import HTTPTypes
import PullRequestHosting
import Testing

@Suite("GitHubHost finds, creates, updates, and deletes the summary comment")
struct GitHubHostCommentTests {
    /// The marker the 3.2 spike put on the comments it recorded.
    let spikeMacOS = SummaryMarker(line: "<!-- steward-spike macos -->")
    let spikeActions = SummaryMarker(line: "<!-- steward-spike actions -->")

    // The spike posted, listed, updated, and deleted one comment; replaying
    // its recordings in order checks every request against what it sent.
    @Test("the spike's recorded round trip replays: create, find, update, delete")
    func recordedRoundTrip() async throws {
        let transport = ScriptedTransport([
            try RecordedResponse(fixture: "issues-create-comment.macos-created"),
            try RecordedResponse(fixture: "issues-list-comments.macos-listed"),
            try RecordedResponse(fixture: "issues-update-comment.macos-updated"),
            try RecordedResponse(fixture: "issues-delete-comment.macos-deleted"),
        ])
        let host = GitHubHost.stubbed(transport, marker: spikeMacOS)
        let postedText = try #require(
            try RecordedResponse(fixture: "issues-create-comment.macos-created").jsonObject()["body"] as? String
        )

        let created = try await host.createSummaryComment(
            onPullRequest: 21,
            body: "Step 3.2 spike round trip; deleted right away."
        )
        #expect(created == SummaryComment(
            id: .init(rawValue: 6_383_467_478),
            body: "Step 3.2 spike round trip; deleted right away.",
            author: "marosoaie",
            webURL: "https://github.com/marosoaie/swift-steward/pull/21#issuecomment-6383467478"
        ))
        #expect(try await host.summaryComments(onPullRequest: 21) == [created])
        let updated = try await host.updateSummaryComment(created.id, body: "Updated.")
        #expect(updated.id == created.id)
        #expect(updated.body == "Updated.")
        try await host.deleteSummaryComment(created.id)

        let sent = await transport.sent
        #expect(sent.map(\.operationID) == [
            "issues/create-comment", "issues/list-comments", "issues/update-comment", "issues/delete-comment",
        ])
        #expect(sent.map(\.method) == [.post, .get, .patch, .delete])
        #expect(sent.map(\.path) == [
            "/repos/marosoaie/swift-steward/issues/21/comments",
            "/repos/marosoaie/swift-steward/issues/21/comments",
            "/repos/marosoaie/swift-steward/issues/comments/6383467478",
            "/repos/marosoaie/swift-steward/issues/comments/6383467478",
        ])
        #expect(sent[0].commentText == postedText)
        #expect(sent[2].commentText == "<!-- steward-spike macos -->\nUpdated.")
        #expect(sent.allSatisfy { $0.headers[.authorization] == "Bearer \(GitHubHost.probeToken)" })
    }

    @Test("Steward's own marker leaves the spike's comment alone")
    func otherMarker() async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "issues-list-comments.macos-listed")])
        #expect(try await GitHubHost.stubbed(transport).summaryComments(onPullRequest: 21).isEmpty)
    }

    // GitHub-Actions[bot]: regression (Codex review), since logins are
    // case-insensitive.
    @Test("with an author set, only that login's marked comments count, in any case", arguments: [
        ("github-actions[bot]", 1),
        ("GitHub-Actions[bot]", 1),
        ("marosoaie", 0),
    ])
    func author(login: String, count: Int) async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "issues-list-comments.actions-listed")])
        let found = try await GitHubHost.stubbed(transport, marker: spikeActions, summaryAuthor: login)
            .summaryComments(onPullRequest: 21)
        #expect(found.count == count)
        #expect(found.allSatisfy { $0.author == "github-actions[bot]" && $0.id.rawValue == 6_383_478_629 })
    }

    @Test("a comment posted as github-actions[bot] maps its author")
    func botCreated() async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "issues-create-comment.actions-created")])
        let created = try await GitHubHost.stubbed(transport, marker: spikeActions)
            .createSummaryComment(onPullRequest: 21, body: "Step 3.2 spike round trip; deleted right away.")
        #expect(created.author == "github-actions[bot]")
        #expect(created.body == "Step 3.2 spike round trip; deleted right away.")
    }

    @Test("an empty list takes one request for the first page of 100")
    func emptyList() async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "issues-list-comments.macos-pr20")])
        #expect(try await GitHubHost.stubbed(transport).summaryComments(onPullRequest: 20).isEmpty)
        let sent = try #require(await transport.sent.only)
        #expect(sent.path == "/repos/marosoaie/swift-steward/issues/20/comments")
        #expect(sent.query == ["per_page": "100", "page": "1"])
    }

    @Test("pages are followed while the link header names a next one, and every summary comes back oldest first")
    func pagination() async throws {
        let transport = ScriptedTransport([
            try RecordedResponse.commentPage([
                try RecordedResponse.comment(id: 1, body: "LGTM"),
                try RecordedResponse.comment(id: 2, body: "<!-- steward-summary -->\nfirst"),
            ], next: 2),
            try RecordedResponse.commentPage(
                [try RecordedResponse.comment(id: 3, body: "> <!-- steward-summary -->\n> quoted")],
                next: 3
            ),
            try RecordedResponse.commentPage(
                [try RecordedResponse.comment(id: 4, body: "<!-- steward-summary -->\r\nsecond, from a race")]
            ),
        ])
        let found = try await GitHubHost.stubbed(transport).summaryComments(onPullRequest: 21)
        #expect(found.map(\.id.rawValue) == [2, 4])
        #expect(found.map(\.body) == ["first", "second, from a race"])
        #expect(await transport.sent.map { $0.query["page"] } == ["1", "2", "3"])
    }

    @Test("an empty page ends the list even when it links a next one")
    func emptyPageEnds() async throws {
        let transport = ScriptedTransport([
            try RecordedResponse.commentPage(
                [try RecordedResponse.comment(id: 1, body: "<!-- steward-summary -->\nfound")],
                next: 2
            ),
            try RecordedResponse.commentPage([], next: 3),
        ])
        #expect(try await GitHubHost.stubbed(transport).summaryComments(onPullRequest: 21).count == 1)
        #expect(await transport.sent.count == 2)
    }

    @Test("a server that always links a next page is given up on after the page limit")
    func endlessPages() async throws {
        let page = try RecordedResponse.commentPage([try RecordedResponse.comment(id: 1, body: "again")], next: 2)
        let transport = ScriptedTransport(Array(repeating: page, count: GitHubHost.maximumCommentPages + 1))
        let error = await #expect(throws: PullRequestHostError.self) {
            _ = try await GitHubHost.stubbed(transport).summaryComments(onPullRequest: 21)
        }
        #expect(error?.kind == .malformedResponse)
        #expect(error?.operation == "issues/list-comments")
        #expect(await transport.sent.count == GitHubHost.maximumCommentPages)
    }

    @Test("a comment without text or without an author is never mistaken for the summary")
    func nullFields() async throws {
        var noText = try RecordedResponse.comment(id: 1, body: "")
        noText["body"] = NSNull()
        var ghost = try RecordedResponse.comment(id: 2, body: "<!-- steward-summary -->\nby a deleted account")
        ghost["user"] = NSNull()
        let page = try RecordedResponse.commentPage([noText, ghost])

        let anyone = try await GitHubHost.stubbed(ScriptedTransport([page])).summaryComments(onPullRequest: 21)
        #expect(anyone.map(\.id.rawValue) == [2])
        #expect(anyone.first?.author == nil)
        let bot = try await GitHubHost.stubbed(ScriptedTransport([page]), summaryAuthor: "github-actions[bot]")
            .summaryComments(onPullRequest: 21)
        #expect(bot.isEmpty)
    }

    @Test("updating a comment deleted by hand fails as not found, so the caller can post a new one")
    func updateDeleted() async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "issues-update-comment.macos-update-deleted")])
        let error = await #expect(throws: PullRequestHostError.self) {
            _ = try await GitHubHost.stubbed(transport).updateSummaryComment(.init(rawValue: 6_383_467_478), body: "x")
        }
        #expect(error == PullRequestHostError(
            kind: .notFound,
            operation: "issues/update-comment",
            status: 404,
            message: "Not Found"
        ))
    }

    @Test("deleting a comment that's already gone succeeds")
    func deleteDeleted() async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "issues-delete-comment.macos-delete-deleted")])
        try await GitHubHost.stubbed(transport).deleteSummaryComment(.init(rawValue: 6_383_467_478))
        #expect(try #require(await transport.sent.only).method == .delete)
    }

    @Test("listing comments on a missing pull request fails as not found")
    func listMissing() async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "issues-list-comments.macos-missing")])
        let error = await #expect(throws: PullRequestHostError.self) {
            _ = try await GitHubHost.stubbed(transport).summaryComments(onPullRequest: 999_999)
        }
        #expect(error?.kind == .notFound)
        #expect(error?.status == 404)
    }

    @Test("a created comment whose text lost its marker keeps the text whole")
    func createdWithoutMarker() async throws {
        let response = try RecordedResponse(status: 201, json: try RecordedResponse.comment(id: 7, body: "bare"))
        let created = try await GitHubHost.stubbed(ScriptedTransport([response]))
            .createSummaryComment(onPullRequest: 21, body: "bare")
        #expect(created.body == "bare")
    }
}
