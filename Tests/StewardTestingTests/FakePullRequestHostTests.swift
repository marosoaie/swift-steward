import StewardTesting
import Testing

@Suite("FakePullRequestHost")
struct FakePullRequestHostTests {
    @Test("it takes what GitHubHost takes by default: 65,536 bytes less the marker line")
    func defaultSize() {
        #expect(FakePullRequestHost().maximumSummarySize == 65_536 - "<!-- steward-summary -->\n".utf8.count)
        #expect(FakePullRequestHost(maximumSummarySize: 10).maximumSummarySize == 10)
    }

    @Test("comments already posted are numbered from 1, and new ones after them")
    func numbersComments() async throws {
        let host = FakePullRequestHost(comments: ["first", "second"])
        let created = try await host.createSummaryComment(onPullRequest: 1, body: "third")
        let comments = await host.comments
        #expect(comments.map(\.id.rawValue) == [1, 2, 3])
        #expect(comments.map(\.body) == ["first", "second", "third"])
        #expect(comments.last == created)
        #expect(created.author == "github-actions[bot]")
        #expect(created.webURL == "https://github.com/octocat/hello-world/pull/1#issuecomment-3")
        #expect(try await host.summaryComments(onPullRequest: 1) == comments)
    }

    @Test("every request is recorded in order, with what it asked for")
    func recordsRequests() async throws {
        let host = FakePullRequestHost(comments: ["old"])
        let id = SummaryComment.ID(rawValue: 1)
        _ = try await host.summaryComments(onPullRequest: 1)
        _ = try await host.pullRequest(number: 1)
        _ = try await host.updateSummaryComment(id, body: "new")
        _ = try await host.createSummaryComment(onPullRequest: 1, body: "again")
        try await host.deleteSummaryComment(SummaryComment.ID(rawValue: 2))
        #expect(await host.requests == [
            .summaryComments(pullRequest: 1),
            .pullRequest(number: 1),
            .updateSummaryComment(id, body: "new"),
            .createSummaryComment(pullRequest: 1, body: "again"),
            .deleteSummaryComment(SummaryComment.ID(rawValue: 2)),
        ])
        #expect(await host.comments.map(\.body) == ["new"])
    }

    @Test("an update changes the text in place")
    func updates() async throws {
        let host = FakePullRequestHost(comments: ["old", "other"])
        let updated = try await host.updateSummaryComment(SummaryComment.ID(rawValue: 2), body: "new")
        #expect(updated.id.rawValue == 2)
        #expect(updated.body == "new")
        #expect(await host.comments.map(\.body) == ["old", "new"])
    }

    @Test("updating a comment that's gone fails as not found")
    func updateOfAMissingComment() async {
        let host = FakePullRequestHost()
        let error = await #expect(throws: PullRequestHostError.self) {
            try await host.updateSummaryComment(SummaryComment.ID(rawValue: 1), body: "new")
        }
        #expect(error?.kind == .notFound)
        #expect(error?.operation == "issues/update-comment")
    }

    @Test("a deletion says whether it deleted the comment")
    func deletes() async throws {
        let host = FakePullRequestHost(comments: ["only"])
        #expect(try await host.deleteSummaryComment(SummaryComment.ID(rawValue: 1)))
        #expect(try await !host.deleteSummaryComment(SummaryComment.ID(rawValue: 1)))
        #expect(await host.comments.isEmpty)
    }

    @Test("a comment of exactly the maximum size posts, and one byte more is rejected", arguments: [false, true])
    func enforcesTheSize(updating: Bool) async throws {
        let host = FakePullRequestHost(comments: ["old"], maximumSummarySize: 4)
        // "é" is two bytes: five bytes in four characters.
        let (fitting, tooLong) = ("abcd", "abcé")
        let post = { (body: String) async throws -> SummaryComment in
            updating
                ? try await host.updateSummaryComment(SummaryComment.ID(rawValue: 1), body: body)
                : try await host.createSummaryComment(onPullRequest: 1, body: body)
        }
        #expect(try await post(fitting).body == fitting)
        let error = await #expect(throws: PullRequestHostError.self) { try await post(tooLong) }
        #expect(error?.kind == .rejected)
        #expect(await !host.comments.map(\.body).contains(tooLong))
    }

    @Test("another pull request's number is not found, as on GitHub", arguments: [
        "pulls/get", "issues/list-comments", "issues/create-comment",
    ])
    func rejectsOtherPullRequests(operation: String) async {
        let host = FakePullRequestHost(pullRequest: .fixture(number: 5))
        let error = await #expect(throws: PullRequestHostError.self) {
            switch operation {
            case "pulls/get": _ = try await host.pullRequest(number: 6)
            case "issues/list-comments": _ = try await host.summaryComments(onPullRequest: 6)
            default: _ = try await host.createSummaryComment(onPullRequest: 6, body: "text")
            }
        }
        #expect(error?.kind == .notFound)
        #expect(error?.operation == operation)
        #expect(await host.comments.isEmpty)
    }

    @Test("a push moves the pull request's head and nothing else")
    func push() async throws {
        let host = FakePullRequestHost()
        await host.push(String(repeating: "f", count: 40))
        var expected = PullRequest.fixture()
        expected.head.commit = String(repeating: "f", count: 40)
        #expect(try await host.pullRequest(number: 1) == expected)
    }
}
