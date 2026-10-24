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
