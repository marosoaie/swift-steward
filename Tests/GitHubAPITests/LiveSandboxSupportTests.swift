import Foundation
@testable import GitHubAPI
import HTTPTypes
import PullRequestHosting
import Testing

/// The fence around the live write test, checked offline: nothing here
/// touches the network.
@Suite("The live write test can reach its sandbox pull request and nothing else")
struct LiveSandboxSupportTests {
    let fence = SandboxOnlyMiddleware(owner: "marosoaie", repository: "steward-sandbox", pullRequest: 1)
    let apiURL = URL(string: "https://api.github.com")!

    @Test("reads in the sandbox repository, comments on its pull request, and comment edits go through", arguments: [
        (HTTPRequest.Method.get, "/repos/marosoaie/steward-sandbox/pulls/1"),
        (.get, "/repos/marosoaie/steward-sandbox/issues/1/comments"),
        (.post, "/repos/marosoaie/steward-sandbox/issues/1/comments"),
        (.patch, "/repos/marosoaie/steward-sandbox/issues/comments/6383467478"),
        (.delete, "/repos/marosoaie/steward-sandbox/issues/comments/6383467478"),
    ])
    func allowed(method: HTTPRequest.Method, path: String) {
        #expect(fence.allows(method: method, path: path, baseURL: apiURL))
    }

    @Test("anything else is refused", arguments: [
        (HTTPRequest.Method.get, "/repos/marosoaie/swift-steward/pulls/1"),
        (.get, "/repos/marosoaie/steward-sandbox-2/pulls/1"),
        (.get, "/repos/marosoaie/steward-sandbox/../swift-steward/pulls/1"),
        (.post, "/repos/marosoaie/steward-sandbox/issues/2/comments"),
        (.post, "/repos/marosoaie/steward-sandbox/issues/11/comments"),
        (.post, "/repos/marosoaie/swift-steward/issues/1/comments"),
        (.patch, "/repos/marosoaie/steward-sandbox/pulls/1"),
        (.patch, "/repos/marosoaie/steward-sandbox/issues/comments/"),
        (.delete, "/repos/marosoaie/steward-sandbox/issues/comments/1/reactions"),
        (.delete, "/repos/marosoaie/swift-steward/issues/comments/6383467478"),
        (.put, "/repos/marosoaie/steward-sandbox/issues/1/comments"),
    ])
    func refused(method: HTTPRequest.Method, path: String) {
        #expect(!fence.allows(method: method, path: path, baseURL: apiURL))
    }

    @Test("another API host is refused")
    func otherHost() {
        let enterprise = URL(string: "https://github.example.com/api/v3")!
        #expect(!fence.allows(method: .get, path: "/repos/marosoaie/steward-sandbox/pulls/1", baseURL: enterprise))
    }

    @Test("a host behind the fence refuses a comment on another pull request before the transport sees it")
    func hostFenced() async throws {
        let transport = ScriptedTransport([])
        let host = GitHubHost(
            owner: "marosoaie",
            repository: "steward-sandbox",
            token: GitHubHost.probeToken,
            apiURL: apiURL,
            transport: transport,
            middlewares: [fence]
        )
        let error = await #expect(throws: PullRequestHostError.self) {
            _ = try await host.createSummaryComment(onPullRequest: 2, body: "x")
        }
        #expect(error?.message?.contains("refused POST") == true, "\(String(describing: error))")
        #expect(await transport.sent.isEmpty)
    }

    @Test("the sandbox comes from the environment, all of it or none")
    func environment() {
        let complete = [
            "STEWARD_SANDBOX_REPOSITORY": "marosoaie/steward-sandbox",
            "STEWARD_SANDBOX_PULL_REQUEST": "1",
            "GITHUB_TOKEN": "t",
        ]
        let sandbox = LiveSandbox(environment: complete)
        #expect(sandbox?.owner == "marosoaie")
        #expect(sandbox?.repository == "steward-sandbox")
        #expect(sandbox?.pullRequest == 1)
        let broken = [
            ["STEWARD_SANDBOX_REPOSITORY": "steward-sandbox"],
            ["STEWARD_SANDBOX_REPOSITORY": "a/b/c"],
            ["STEWARD_SANDBOX_REPOSITORY": "/steward-sandbox"],
            ["STEWARD_SANDBOX_PULL_REQUEST": "0"],
            ["STEWARD_SANDBOX_PULL_REQUEST": "one"],
            ["GITHUB_TOKEN": ""],
        ]
        broken.forEach { override in
            #expect(LiveSandbox(environment: complete.merging(override) { $1 }) == nil, "\(override)")
        }
        #expect(LiveSandbox(environment: complete.filter { $0.key != "GITHUB_TOKEN" }) == nil)
    }
}
