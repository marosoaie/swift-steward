import Foundation
@testable import GitHubAPI
import OpenAPIRuntime
import Testing

/// A client that answers every request with the named fixture.
func client(replaying fixture: String) throws -> Client {
    let url = try #require(
        Bundle.module.url(forResource: fixture, withExtension: "http", subdirectory: "Fixtures"),
        "no fixture \(fixture).http"
    )
    return Client(
        serverURL: URL(string: "https://api.github.com")!,
        transport: FixtureTransport(recorded: try RecordedResponse(contentsOf: url))
    )
}

let owner = "marosoaie"
let repo = "swift-steward"

@Suite("Recorded responses decode with the generated types")
struct FixtureDecodingTests {
    @Test("pulls/get decodes real pull requests", arguments: [
        ("pulls-get.macos-pr1", 1),
        ("pulls-get.macos-pr20", 20),
        ("pulls-get.macos-pr21", 21),
    ])
    func pullRequest(fixture: String, number: Int) async throws {
        let output = try await client(replaying: fixture)
            .pullsGet(path: .init(owner: owner, repo: repo, pullNumber: number))
        #expect(try output.ok.body.json.number == number)
    }

    @Test("issues/list-comments decodes an empty page")
    func emptyComments() async throws {
        let output = try await client(replaying: "issues-list-comments.macos-pr20")
            .issuesListComments(path: .init(owner: owner, repo: repo, issueNumber: 20))
        #expect(try output.ok.body.json.isEmpty)
    }

    @Test("a comment's create, list, update and delete responses decode")
    func commentRoundTrip() async throws {
        let created = try await client(replaying: "issues-create-comment.macos-created")
            .issuesCreateComment(
                path: .init(owner: owner, repo: repo, issueNumber: 21),
                body: .json(.init(body: "spike"))
            )
        let comment = try created.created.body.json
        #expect(comment.body?.hasPrefix("<!-- steward-spike") == true)

        let listed = try await client(replaying: "issues-list-comments.macos-listed")
            .issuesListComments(path: .init(owner: owner, repo: repo, issueNumber: 21))
        let match = try #require(try listed.ok.body.json.first { $0.id == comment.id })
        #expect(match.bodyHtml != nil && match.bodyText != nil)

        let path = Operations.IssuesUpdateComment.Input.Path(owner: owner, repo: repo, commentId: comment.id)
        let updated = try await client(replaying: "issues-update-comment.macos-updated")
            .issuesUpdateComment(path: path, body: .json(.init(body: "spike")))
        #expect(try updated.ok.body.json.id == comment.id)

        let deleted = try await client(replaying: "issues-delete-comment.macos-deleted")
            .issuesDeleteComment(path: .init(owner: owner, repo: repo, commentId: comment.id))
        _ = try deleted.noContent
    }

    @Test("updating or deleting a deleted comment gets a 404 neither operation declares")
    func deletedComment() async throws {
        let update = try await client(replaying: "issues-update-comment.macos-update-deleted")
            .issuesUpdateComment(
                path: .init(owner: owner, repo: repo, commentId: 1),
                body: .json(.init(body: "gone"))
            )
        let delete = try await client(replaying: "issues-delete-comment.macos-delete-deleted")
            .issuesDeleteComment(path: .init(owner: owner, repo: repo, commentId: 1))
        guard case .undocumented(statusCode: 404, _) = update, case .undocumented(statusCode: 404, _) = delete else {
            Issue.record("expected undocumented 404s, got \(update) and \(delete)")
            return
        }
    }

    @Test("a missing pull request or issue decodes as the declared 404")
    func notFound() async throws {
        let pull = try await client(replaying: "pulls-get.macos-missing")
            .pullsGet(path: .init(owner: owner, repo: repo, pullNumber: 999_999))
        #expect(try pull.notFound.body.json.message == "Not Found")
        let comments = try await client(replaying: "issues-list-comments.macos-missing")
            .issuesListComments(path: .init(owner: owner, repo: repo, issueNumber: 999_999))
        #expect(try comments.notFound.body.json.message == "Not Found")
    }

    @Test("a 401 is undocumented: no operation declares it")
    func badCredentials() async throws {
        let output = try await client(replaying: "pulls-get.macos-bad-token")
            .pullsGet(path: .init(owner: owner, repo: repo, pullNumber: 20))
        guard case .undocumented(statusCode: 401, _) = output else {
            Issue.record("expected an undocumented 401, got \(output)")
            return
        }
    }

    @Test("the undeclared diff media type fails to decode")
    func diffMediaType() async throws {
        let error = await #expect(throws: ClientError.self) {
            _ = try await client(replaying: "pulls-get.macos-diff")
                .pullsGet(path: .init(owner: owner, repo: repo, pullNumber: 20))
        }
        let reason = error.map { String(describing: $0.underlyingError) } ?? ""
        #expect(reason.contains("application/vnd.github.diff"), "\(reason)")
    }
}
