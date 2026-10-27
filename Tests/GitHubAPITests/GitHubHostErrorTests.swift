import Foundation
@testable import GitHubAPI
import HTTPTypes
import PullRequestHosting
import Testing

@Suite("GitHubHost maps every failure to one error type, and never shows its token")
struct GitHubHostErrorTests {
    /// The error `call` threw, failing the test when it threw another or
    /// none.
    static func hostError(
        _ responses: [RecordedResponse],
        _ call: (GitHubHost) async throws -> Void = { _ = try await $0.pullRequest(number: 20) }
    ) async -> PullRequestHostError? {
        await #expect(throws: PullRequestHostError.self) {
            try await call(.stubbed(ScriptedTransport(responses)))
        }
    }

    @Test("a recorded bad token, which no operation declares, fails as unauthorized with GitHub's message")
    func badToken() async throws {
        let error = await Self.hostError([try RecordedResponse(fixture: "pulls-get.macos-bad-token")])
        #expect(error == PullRequestHostError(
            kind: .unauthorized,
            operation: "pulls/get",
            status: 401,
            message: "Bad credentials"
        ))
    }

    @Test("a recorded missing pull request fails as not found")
    func missing() async throws {
        let error = await Self.hostError([try RecordedResponse(fixture: "pulls-get.macos-missing")]) {
            _ = try await $0.pullRequest(number: 999_999)
        }
        #expect(error == PullRequestHostError(
            kind: .notFound,
            operation: "pulls/get",
            status: 404,
            message: "Not Found"
        ))
    }

    @Test("a recorded success in an undeclared media type is malformed, naming the content type")
    func diffMediaType() async throws {
        let error = await Self.hostError([try RecordedResponse(fixture: "pulls-get.macos-diff")])
        #expect(error?.kind == .malformedResponse)
        #expect(error?.status == 200)
        #expect(error?.message?.contains("application/vnd.github.diff") == true, "\(String(describing: error))")
    }

    /// An answer GitHub can give but the fixtures can't record safely, and
    /// the kind it must map to.
    struct StatusCase: Sendable, CustomTestStringConvertible {
        let status: Int
        var headers: [String: String] = [:]
        let message: String
        let kind: PullRequestHostError.Kind

        var testDescription: String {
            "\(status) \(headers) \"\(message)\" → \(kind)"
        }
    }

    @Test("each status maps to the kind a caller acts on, declared or not", arguments: [
        StatusCase(status: 403, message: "Resource not accessible by integration", kind: .forbidden),
        StatusCase(
            status: 403,
            headers: ["x-ratelimit-remaining": "0"],
            message: "Over the limit.",
            kind: .rateLimited
        ),
        StatusCase(status: 403, headers: ["retry-after": "60"], message: "Slow down.", kind: .rateLimited),
        StatusCase(
            status: 403,
            headers: ["x-ratelimit-remaining": "4"],
            message: "Must have admin rights to Repository.",
            kind: .forbidden
        ),
        StatusCase(status: 429, headers: ["retry-after": "30"], message: "Too many requests.", kind: .rateLimited),
        StatusCase(status: 403, message: "API rate limit exceeded for user ID 1.", kind: .rateLimited),
        StatusCase(status: 403, message: "You have exceeded a secondary rate limit.", kind: .rateLimited),
        StatusCase(status: 429, message: "Too many requests.", kind: .rateLimited),
        StatusCase(status: 422, message: "Validation Failed", kind: .rejected),
        StatusCase(status: 500, message: "Server Error", kind: .serverError),
        StatusCase(status: 502, message: "Bad Gateway", kind: .serverError),
        StatusCase(status: 503, message: "Service Unavailable", kind: .serverError),
        StatusCase(status: 304, message: "Not Modified", kind: .unexpectedStatus),
        StatusCase(status: 406, message: "Unsupported 'Accept' header", kind: .unexpectedStatus),
        StatusCase(status: 418, message: "I'm a teapot", kind: .unexpectedStatus),
    ])
    func statuses(_ answer: StatusCase) async throws {
        let body = [
            "message": answer.message,
            "documentation_url": "https://docs.github.com/rest",
            "status": "\(answer.status)",
        ]
        let response = try RecordedResponse(status: answer.status, headers: answer.headers, json: body)
        let error = await Self.hostError([response])
        #expect(error?.kind == answer.kind)
        #expect(error?.status == answer.status)
        // pulls/get declares 304 without a body.
        #expect(error?.message == (answer.status == 304 ? nil : answer.message))
    }

    @Test("issues/create-comment's declared 403 tells a rate limit from a missing permission", arguments: [
        ("Resource not accessible by integration", PullRequestHostError.Kind.forbidden),
        ("You have exceeded a secondary rate limit and have been temporarily blocked from content creation.",
         .rateLimited),
    ])
    func createForbidden(message: String, kind: PullRequestHostError.Kind) async throws {
        let response = try RecordedResponse(status: 403, json: ["message": message])
        let error = await Self.hostError([response]) {
            _ = try await $0.createSummaryComment(onPullRequest: 21, body: "x")
        }
        #expect(error == PullRequestHostError(
            kind: kind,
            operation: "issues/create-comment",
            status: 403,
            message: message
        ))
    }

    @Test("issues with comments turned off answer 410, which fails as not found")
    func gone() async throws {
        let response = try RecordedResponse(status: 410, json: ["message": "Issues are disabled for this repo"])
        let error = await Self.hostError([response]) { _ = try await $0.summaryComments(onPullRequest: 21) }
        #expect(error?.kind == .notFound)
        #expect(error?.message == "Issues are disabled for this repo")
    }

    @Test("an error status with a body that isn't GitHub's JSON still maps by its status", arguments: [
        (404, PullRequestHostError.Kind.notFound),
        (502, .serverError),
    ])
    func unreadableErrorBody(status: Int, kind: PullRequestHostError.Kind) async throws {
        let html = RecordedResponse(
            unfiltered: HTTPResponse(
                status: .init(code: status),
                headerFields: [.contentType: "text/html"]
            ),
            body: Data("<html>proxy error</html>".utf8)
        )
        let error = await Self.hostError([html])
        #expect(error == PullRequestHostError(kind: kind, operation: "pulls/get", status: status))
    }

    @Test("a request that gets no response fails as a network error")
    func network() async throws {
        let host = GitHubHost.stubbed(FailingTransport(error: URLError(.notConnectedToInternet)))
        let error = await #expect(throws: PullRequestHostError.self) {
            try await host.deleteSummaryComment(.init(rawValue: 1))
        }
        #expect(error?.kind == .network)
        #expect(error?.operation == "issues/delete-comment")
        #expect(error?.status == nil)
        #expect(error?.message != nil)
    }

    @Test("cancellation stays a CancellationError")
    func cancellation() async throws {
        let host = GitHubHost.stubbed(FailingTransport(error: CancellationError()))
        await #expect(throws: CancellationError.self) {
            _ = try await host.summaryComments(onPullRequest: 21)
        }
    }

    // Regression (Codex review): URLSession answers cancellation with
    // URLError(.cancelled), which used to come back as a network error.
    @Test("cancelling a request in flight is a CancellationError, though the transport throws URLError(.cancelled)")
    func cancellationInFlight() async throws {
        let task = Task {
            try await GitHubHost.stubbed(HangingTransport()).summaryComments(onPullRequest: 21)
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) {
            _ = try result.get()
        }
    }

    @Test("URLError(.cancelled) without a cancelled task is a network error")
    func cancelledByURLSessionAlone() async throws {
        let host = GitHubHost.stubbed(FailingTransport(error: URLError(.cancelled)))
        let error = await #expect(throws: PullRequestHostError.self) {
            _ = try await host.summaryComments(onPullRequest: 21)
        }
        #expect(error?.kind == .network)
    }

    @Test("the error reads as one line: operation, kind, status, and message")
    func descriptions() {
        let full = PullRequestHostError(
            kind: .notFound,
            operation: "issues/update-comment",
            status: 404,
            message: "Not Found"
        )
        #expect(full.description == "issues/update-comment failed (notFound): HTTP 404: Not Found")
        let network = PullRequestHostError(kind: .network, operation: "pulls/get", message: "offline")
        #expect(network.description == "pulls/get failed (network): offline")
        let bare = PullRequestHostError(kind: .unexpectedStatus, operation: "pulls/get")
        #expect(bare.description == "pulls/get failed (unexpectedStatus)")
    }

    @Test("the token never shows up in the host's description, debug output, or dump")
    func tokenRedacted() {
        let host = GitHubHost.stubbed(FailingTransport(error: URLError(.notConnectedToInternet)))
        var dumped = ""
        dump(host, to: &dumped)
        let renderings = [String(describing: host), String(reflecting: host), "\(host)", dumped]
        renderings.forEach { #expect(!$0.contains(GitHubHost.probeToken), "\($0)") }
        #expect(String(describing: host) == "GitHubHost(marosoaie/swift-steward at https://api.github.com)")
        #expect(dumped.contains("<redacted>"))
    }

    @Test("the token never shows up in an error, whatever failed", arguments: [
        "pulls-get.macos-bad-token", "pulls-get.macos-diff", "pulls-get.macos-missing",
    ])
    func tokenNotInErrors(fixture: String) async throws {
        let error = await Self.hostError([try RecordedResponse(fixture: fixture)])
        var dumped = ""
        dump(error, to: &dumped)
        #expect(!dumped.contains(GitHubHost.probeToken))
        #expect(!String(describing: error).contains(GitHubHost.probeToken))
    }
}
