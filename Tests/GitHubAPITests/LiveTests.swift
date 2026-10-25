import Foundation
@testable import GitHubAPI
import OpenAPIRuntime
import Testing

/// Real responses from api.github.com decode with the generated client, to
/// catch upstream changes the recorded fixtures can't show. Opt-in through
/// `STEWARD_LIVE_GITHUB_TESTS=1` (see `LiveGitHub`), and read-only: every
/// client refuses anything but a GET before it reaches the network.
@Suite("Live GitHub API responses decode with the generated client (opt-in)", .enabled(if: LiveGitHub.current != nil))
struct LiveTests {
    /// Same-repository and merged: the pull request the fixtures recorded.
    static let own = (owner: "marosoaie", repo: "swift-steward", number: 20)
    /// From a fork, merged, with nine comments: what this repository has
    /// none of. Public and closed, so it changes rarely.
    static let fork = (owner: "apple", repo: "swift-openapi-generator", number: 883)

    let live: LiveGitHub

    init() throws {
        live = try #require(LiveGitHub.current)
    }

    @Test("pulls/get decodes a same-repository and a fork pull request")
    func pullRequests() async throws {
        let own = try await live.client("own")
            .pullsGet(path: .init(owner: Self.own.owner, repo: Self.own.repo, pullNumber: Self.own.number))
            .ok.body.json
        #expect(own.number == Self.own.number)
        #expect(own.merged)
        #expect(own.head.repo.fullName == own.base.repo.fullName)

        let fork = try await live.client("fork")
            .pullsGet(path: .init(owner: Self.fork.owner, repo: Self.fork.repo, pullNumber: Self.fork.number))
            .ok.body.json
        #expect(fork.number == Self.fork.number)
        #expect(fork.base.repo.fullName == "\(Self.fork.owner)/\(Self.fork.repo)")
        #expect(fork.head.repo.fullName != fork.base.repo.fullName)
    }

    @Test("issues/list-comments decodes two pages of a pull request's comments, linked by the link header")
    func commentPages() async throws {
        let path = Operations.IssuesListComments.Input.Path(
            owner: Self.fork.owner,
            repo: Self.fork.repo,
            issueNumber: Self.fork.number
        )
        let accept = "application/vnd.github.full+json"
        let first = try await live.client("page1", accept: accept)
            .issuesListComments(path: path, query: .init(perPage: 5, page: 1))
            .ok
        let link = try #require(first.headers.link)
        #expect(link.contains(#"rel="next""#), "\(link)")
        let firstPage = try first.body.json
        #expect(firstPage.count == 5)
        #expect(firstPage.allSatisfy { $0.bodyHtml != nil && $0.bodyText != nil })

        let secondPage = try await live.client("page2", accept: accept)
            .issuesListComments(path: path, query: .init(perPage: 5, page: 2))
            .ok.body.json
        #expect(!secondPage.isEmpty)
        #expect(Set(firstPage.map(\.id)).isDisjoint(with: secondPage.map(\.id)))
    }

    @Test("a missing pull request or issue answers the 404 upstream declares")
    func notFound() async throws {
        let pull = try await live.client("missing")
            .pullsGet(path: .init(owner: Self.own.owner, repo: Self.own.repo, pullNumber: 999_999))
        #expect(try pull.notFound.body.json.message == "Not Found")
        let comments = try await live.client("missing")
            .issuesListComments(path: .init(owner: Self.own.owner, repo: Self.own.repo, issueNumber: 999_999))
        #expect(try comments.notFound.body.json.message == "Not Found")
    }

    @Test("a bad token still answers a 401, which no operation declares")
    func badToken() async throws {
        let output = try await live.client("bad-token", token: "invalid")
            .pullsGet(path: .init(owner: Self.own.owner, repo: Self.own.repo, pullNumber: Self.own.number))
        guard case .undocumented(statusCode: 401, _) = output else {
            Issue.record("expected an undocumented 401, got \(output)")
            return
        }
    }

    @Test("the diff media type is still undeclared, so the client can't decode it")
    func diffMediaType() async throws {
        let error = await #expect(throws: ClientError.self) {
            _ = try await live.client("diff", accept: "application/vnd.github.diff")
                .pullsGet(path: .init(owner: Self.own.owner, repo: Self.own.repo, pullNumber: Self.own.number))
        }
        let reason = error.map { String(describing: $0.underlyingError) } ?? ""
        #expect(reason.contains("application/vnd.github.diff"), "\(reason)")
    }
}
