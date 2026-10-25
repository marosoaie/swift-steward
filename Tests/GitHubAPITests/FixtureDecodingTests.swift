import Foundation
@testable import GitHubAPI
import OpenAPIRuntime
import Testing

/// Responses recorded from this repository's PRs on 2026-10-24 decode with
/// the generated types, through the client's real decoding path.
@Suite("Recorded responses decode with the generated client")
struct FixtureDecodingTests {
    let owner = "marosoaie"
    let repo = "swift-steward"

    @Test("pulls/get decodes a closed, a merged and an open draft pull request", arguments: [
        ("pulls-get.macos-pr1", 1),
        ("pulls-get.macos-pr20", 20),
        ("pulls-get.macos-pr21", 21),
    ])
    func pullRequest(fixture: String, number: Int) async throws {
        let output = try await Client.replaying(fixture)
            .pullsGet(path: .init(owner: owner, repo: repo, pullNumber: number))
        let pull = try output.ok.body.json
        #expect(pull.number == number)
        #expect(pull.base.repo.fullName == "\(owner)/\(repo)")
    }

    @Test("issues/list-comments decodes an empty page")
    func emptyComments() async throws {
        let output = try await Client.replaying("issues-list-comments.macos-pr20")
            .issuesListComments(path: .init(owner: owner, repo: repo, issueNumber: 20))
        #expect(try output.ok.body.json.isEmpty)
    }

    @Test("a comment's create, list, update and delete responses decode")
    func commentRoundTrip() async throws {
        let created = try await Client.replaying("issues-create-comment.macos-created")
            .issuesCreateComment(
                path: .init(owner: owner, repo: repo, issueNumber: 21),
                body: .json(.init(body: "comment"))
            )
        let comment = try created.created.body.json

        let listed = try await Client.replaying("issues-list-comments.macos-listed")
            .issuesListComments(path: .init(owner: owner, repo: repo, issueNumber: 21))
        let match = try #require(try listed.ok.body.json.first { $0.id == comment.id })
        // Recorded with Accept: application/vnd.github.full+json.
        #expect(match.bodyHtml != nil && match.bodyText != nil)

        let updated = try await Client.replaying("issues-update-comment.macos-updated")
            .issuesUpdateComment(
                path: .init(owner: owner, repo: repo, commentId: comment.id),
                body: .json(.init(body: "comment"))
            )
        #expect(try updated.ok.body.json.id == comment.id)

        let deleted = try await Client.replaying("issues-delete-comment.macos-deleted")
            .issuesDeleteComment(path: .init(owner: owner, repo: repo, commentId: comment.id))
        _ = try deleted.noContent
    }

    @Test("a comment by github-actions[bot] decodes, app permissions and all")
    func botComment() async throws {
        let created = try await Client.replaying("issues-create-comment.actions-created")
            .issuesCreateComment(
                path: .init(owner: owner, repo: repo, issueNumber: 21),
                body: .json(.init(body: "comment"))
            )
        let comment = try created.created.body.json
        #expect(comment.user?.login == "github-actions[bot]")
        let app = try #require(comment.performedViaGithubApp)
        #expect(app.slug == "github-actions")
        // Permission names the schema doesn't list land in additionalProperties.
        #expect(app.permissions.additionalProperties["pull_requests"] == "write")

        let listed = try await Client.replaying("issues-list-comments.actions-listed")
            .issuesListComments(path: .init(owner: owner, repo: repo, issueNumber: 21))
        #expect(try listed.ok.body.json.contains { $0.id == comment.id })
    }

    @Test("a missing pull request or issue decodes as the 404 upstream declares")
    func notFound() async throws {
        let pull = try await Client.replaying("pulls-get.macos-missing")
            .pullsGet(path: .init(owner: owner, repo: repo, pullNumber: 999_999))
        #expect(try pull.notFound.body.json.message == "Not Found")
        let comments = try await Client.replaying("issues-list-comments.macos-missing")
            .issuesListComments(path: .init(owner: owner, repo: repo, issueNumber: 999_999))
        #expect(try comments.notFound.body.json.message == "Not Found")
    }

    /// Deliberately not fixed in the spec: the host seam (3.5) maps every
    /// undocumented status to one error.
    @Test("a 401 stays undocumented: no operation declares it")
    func badCredentials() async throws {
        let output = try await Client.replaying("pulls-get.macos-bad-token")
            .pullsGet(path: .init(owner: owner, repo: repo, pullNumber: 20))
        guard case .undocumented(statusCode: 401, _) = output else {
            Issue.record("expected an undocumented 401, got \(output)")
            return
        }
    }

    /// Deliberately not fixed in the spec: Steward reads diffs from the
    /// checkout, never through the API.
    @Test("the undeclared diff media type fails to decode, naming the content type")
    func diffMediaType() async throws {
        let error = await #expect(throws: ClientError.self) {
            _ = try await Client.replaying("pulls-get.macos-diff")
                .pullsGet(path: .init(owner: owner, repo: repo, pullNumber: 20))
        }
        let reason = error.map { String(describing: $0.underlyingError) } ?? ""
        #expect(reason.contains("application/vnd.github.diff"), "\(reason)")
    }

    // Reads the source tree, not the bundle, so a fixture committed without
    // a test fails here instead of sitting unchecked.
    @Test("every recorded response and event payload is replayed by a test")
    func everyFixtureIsReplayed() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined()
        let fixtures = try FileManager.default
            .contentsOfDirectory(at: folder.appendingPathComponent("Fixtures"), includingPropertiesForKeys: nil)
            .map { $0.deletingPathExtension().lastPathComponent }
        try #require(!fixtures.isEmpty)
        fixtures.forEach { fixture in
            #expect(sources.contains("\"\(fixture)\""), "no test replays \(fixture)")
        }
    }
}
