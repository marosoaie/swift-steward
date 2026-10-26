import Foundation
@testable import GitHubAPI
import HTTPTypes
import PullRequestHosting
import Testing

/// What a pull request's JSON says, read with `JSONSerialization` instead of
/// the generated types: the oracle for the host's mapping.
func expectedPullRequest(_ json: [String: Any]) throws -> PullRequest {
    func branch(_ key: String) throws -> PullRequest.Branch {
        let end = try #require(json[key] as? [String: Any])
        let repo = try #require(end["repo"] as? [String: Any])
        return PullRequest.Branch(
            name: try #require(end["ref"] as? String),
            commit: try #require(end["sha"] as? String),
            repository: try #require(repo["full_name"] as? String)
        )
    }
    let merged = try #require(json["merged"] as? Bool)
    let state = try #require(json["state"] as? String)
    let labels = try #require(json["labels"] as? [[String: Any]])
    return PullRequest(
        number: try #require(json["number"] as? Int),
        title: try #require(json["title"] as? String),
        body: json["body"] as? String ?? "",
        author: try #require((json["user"] as? [String: Any])?["login"] as? String),
        state: merged ? .merged : state == "open" ? .open : .closed,
        isDraft: json["draft"] as? Bool ?? false,
        base: try branch("base"),
        head: try branch("head"),
        labels: labels.compactMap { $0["name"] as? String },
        webURL: try #require(json["html_url"] as? String),
        additions: try #require(json["additions"] as? Int),
        deletions: try #require(json["deletions"] as? Int),
        changedFiles: try #require(json["changed_files"] as? Int),
        commits: try #require(json["commits"] as? Int)
    )
}

@Suite("GitHubHost reads a pull request's metadata")
struct GitHubHostPullRequestTests {
    @Test("a recorded closed, merged, and open draft pull request map field for field", arguments: [
        ("pulls-get.macos-pr1", 1, PullRequest.State.closed, false),
        ("pulls-get.macos-pr20", 20, .merged, false),
        ("pulls-get.macos-pr21", 21, .open, true),
    ])
    func recorded(fixture: String, number: Int, state: PullRequest.State, isDraft: Bool) async throws {
        let recorded = try RecordedResponse(fixture: fixture)
        let pull = try await GitHubHost.stubbed(ScriptedTransport([recorded])).pullRequest(number: number)
        #expect(pull == (try expectedPullRequest(recorded.jsonObject())))
        #expect(pull.number == number)
        #expect(pull.state == state)
        #expect(pull.isDraft == isDraft)
        #expect(!pull.isFromFork)
    }

    @Test("pulls/get goes out as a GET with GitHub's headers and the token")
    func request() async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "pulls-get.macos-pr20")])
        _ = try await GitHubHost.stubbed(transport).pullRequest(number: 20)
        let sent = try #require(await transport.sent.only)
        #expect(sent.operationID == "pulls/get")
        #expect(sent.method == .get)
        #expect(sent.path == "/repos/marosoaie/swift-steward/pulls/20")
        #expect(sent.headers[.authorization] == "Bearer \(GitHubHost.probeToken)")
        #expect(sent.headers[.userAgent] == "swift-steward")
        #expect(sent.headers[HTTPField.Name("x-github-api-version")!] == "2022-11-28")
        #expect(sent.headers[.accept] == "application/json")
    }

    @Test("an empty token sends no authorization header")
    func emptyToken() async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "pulls-get.macos-pr20")])
        let host = GitHubHost(
            owner: "marosoaie",
            repository: "swift-steward",
            token: "",
            apiURL: URL(string: "https://api.github.com")!,
            transport: transport
        )
        _ = try await host.pullRequest(number: 20)
        #expect(try #require(await transport.sent.only).headers[.authorization] == nil)
    }

    @Test("a GitHub Enterprise API URL keeps its path prefix")
    func enterpriseURL() async throws {
        let transport = ScriptedTransport([try RecordedResponse(fixture: "pulls-get.macos-pr20")])
        let host = GitHubHost(
            owner: "marosoaie",
            repository: "swift-steward",
            token: nil,
            apiURL: URL(string: "https://github.example.com/api/v3")!,
            transport: transport
        )
        _ = try await host.pullRequest(number: 20)
        // The transport joins the two, as URLSessionTransport does.
        let sent = try #require(await transport.sent.only)
        #expect(sent.baseURL.absoluteString == "https://github.example.com/api/v3")
        #expect(sent.path == "/repos/marosoaie/swift-steward/pulls/20")
    }

    /// Steward reads the pull request from GITHUB_EVENT_PATH through
    /// `PullRequestEvent`, with this mapping.
    @Test("an Actions event's pull request maps like a pulls/get response", arguments: [
        "pull-request-event.opened",
        "pull-request-event.synchronize",
    ])
    func eventPayload(fixture: String) throws {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let event = try PullRequestEvent(payload: data)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(event.pullRequest == (try expectedPullRequest(#require(json["pull_request"] as? [String: Any]))))
        #expect(event.action == json["action"] as? String)
        #expect(event.pullRequest.state == .open)
    }

    @Test("a payload that isn't a pull request event's fails to decode", arguments: [
        "{}",
        #"{"action": "opened"}"#,
        #"{"ref": "refs/heads/main", "before": "0", "after": "1"}"#,
        "[]",
    ])
    func notAnEvent(payload: String) {
        #expect(throws: DecodingError.self) {
            try PullRequestEvent(payload: Data(payload.utf8))
        }
    }

    @Test("a pull request whose head is in another repository is from a fork")
    func fork() {
        let base = PullRequest.Branch(name: "main", commit: "a", repository: "apple/swift-openapi-generator")
        let head = PullRequest.Branch(name: "fix", commit: "b", repository: "someone/swift-openapi-generator")
        let pull = PullRequest(
            number: 1, title: "", body: "", author: "someone", state: .open, isDraft: false,
            base: base, head: head, labels: [], webURL: "", additions: 0, deletions: 0, changedFiles: 0, commits: 1
        )
        #expect(pull.isFromFork)
        var sameRepository = pull
        sameRepository.head.repository = base.repository
        #expect(!sameRepository.isFromFork)
    }
}
