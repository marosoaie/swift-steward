import Foundation
@testable import GitHubAPI
import PullRequestHosting
import Testing

/// GitHubHost against api.github.com, read-only: the pull requests and
/// comments `LiveTests` reads, each result compared with the raw response
/// it came from. Opt-in like `LiveTests`, through
/// `STEWARD_LIVE_GITHUB_TESTS=1`.
@Suite(
    "GitHubHost reads real pull requests and finds comments across pages (opt-in)",
    .enabled(if: LiveGitHub.current != nil)
)
struct LiveHostTests {
    let live: LiveGitHub

    init() throws {
        live = try #require(LiveGitHub.current)
    }

    @Test("a same-repository and a fork pull request map field for field from the response they came from",
          arguments: [false, true])
    func pullRequest(fromFork: Bool) async throws {
        let (owner, repo, number) = fromFork ? LiveTests.fork : LiveTests.own
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pull = try await live.host(owner: owner, repository: repo, scenario: "host", recordDirectory: directory)
            .pullRequest(number: number)
        let recorded = try RecordedResponse(contentsOf: directory.appendingPathComponent("pulls-get.live-host.http"))
        #expect(pull == (try expectedPullRequest(recorded.jsonObject())))
        #expect(pull.number == number)
        #expect(pull.state == .merged)
        #expect(pull.isFromFork == fromFork)
    }

    // Matches on the first line of the fork pull request's last comment, which
    // sits on the second page at five a page; the oracle is one page of 100.
    @Test("a marker on the second page is found at five comments a page, as one page of 100 finds it")
    func pagination() async throws {
        let (owner, repo, number) = LiveTests.fork
        let all = try await live.client("oracle")
            .issuesListComments(path: .init(owner: owner, repo: repo, issueNumber: number), query: .init(perPage: 100))
            .ok.body.json
        try #require(all.count > 5, "the oracle needs a second page")
        // Bytes, as SummaryMarker compares them: "\r\n" is one Character.
        let firstLine = try #require(all.last?.body).utf8.prefix { $0 != UInt8(ascii: "\n") }
        let marker = SummaryMarker(line: String(
            decoding: firstLine.last == UInt8(ascii: "\r") ? firstLine.dropLast() : firstLine,
            as: UTF8.self
        ))
        let expected = all.filter { $0.body.flatMap(marker.body(ofMarked:)) != nil }.map(\.id)

        let found = try await live.host(
            owner: owner,
            repository: repo,
            scenario: "host-pages",
            marker: marker,
            commentsPerPage: 5
        ).summaryComments(onPullRequest: number)
        #expect(found.map(\.id.rawValue) == expected)
        #expect(found.last?.id.rawValue == all.last?.id)
        #expect(try await live.host(owner: owner, repository: repo, scenario: "host-none", commentsPerPage: 5)
            .summaryComments(onPullRequest: number).isEmpty)
    }

    @Test("a missing pull request fails as not found, and a bad token as unauthorized")
    func failures() async throws {
        let (owner, repo, number) = LiveTests.own
        let missing = await #expect(throws: PullRequestHostError.self) {
            _ = try await live.host(owner: owner, repository: repo, scenario: "host-missing")
                .pullRequest(number: 999_999)
        }
        #expect(missing?.kind == .notFound)
        let badToken = await #expect(throws: PullRequestHostError.self) {
            _ = try await live.host(owner: owner, repository: repo, scenario: "host-bad-token", token: "invalid")
                .pullRequest(number: number)
        }
        #expect(badToken?.kind == .unauthorized)
        #expect(badToken?.message == "Bad credentials")
    }
}
