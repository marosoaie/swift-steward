import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import Steward
import Testing

/// The live summary comment test's fence, offline.
@Suite("The live test's fence")
struct OwnCommentsMiddlewareTests {
    static let api = URL(string: "https://api.github.com")!

    /// Sends `method` to `path` through `fence`, answering a comment's
    /// creation with comment `created`, and says whether it went through.
    static func passes(
        _ method: HTTPRequest.Method,
        _ path: String,
        through fence: OwnCommentsMiddleware,
        baseURL: URL = api,
        created: Int64 = 7
    ) async -> Bool {
        do {
            _ = try await fence.intercept(
                HTTPRequest(method: method, scheme: "https", authority: "api.github.com", path: path),
                body: nil,
                baseURL: baseURL,
                operationID: "x"
            ) { request, _, _ in
                guard request.method == .post else { return (HTTPResponse(status: .ok), nil) }
                return (HTTPResponse(status: .created), HTTPBody(#"{"id": \#(created), "body": "b"}"#))
            }
            return true
        } catch {
            return false
        }
    }

    static func fence() -> OwnCommentsMiddleware {
        OwnCommentsMiddleware(repository: RepositoryName("o/r")!, pullRequest: 29)
    }

    @Test("reading the pull request and its comments, and commenting on it, go through")
    func allowed() async {
        let fence = Self.fence()
        #expect(await Self.passes(.get, "/repos/o/r/pulls/29", through: fence))
        #expect(await Self.passes(.get, "/repos/o/r/issues/29/comments?per_page=2&page=3", through: fence))
        #expect(await Self.passes(.post, "/repos/o/r/issues/29/comments", through: fence))
    }

    @Test("only comments created through the fence can be edited or deleted")
    func ownComments() async {
        let fence = Self.fence()
        #expect(await !Self.passes(.patch, "/repos/o/r/issues/comments/7", through: fence))
        #expect(await Self.passes(.post, "/repos/o/r/issues/29/comments", through: fence, created: 7))
        #expect(await Self.passes(.patch, "/repos/o/r/issues/comments/7", through: fence))
        #expect(await Self.passes(.delete, "/repos/o/r/issues/comments/7", through: fence))
        #expect(await !Self.passes(.delete, "/repos/o/r/issues/comments/8", through: fence))
        #expect(await !Self.passes(.delete, "/repos/o/r/issues/comments/7x", through: fence))
    }

    @Test("everything else is refused before it's sent", arguments: [
        (HTTPRequest.Method.get, "/repos/o/r/pulls/28"),
        (.get, "/repos/o/r/issues/28/comments"),
        (.get, "/repos/o/other/pulls/29"),
        (.get, "/repos/o/r/../other/pulls/29"),
        (.get, "/user"),
        (.post, "/repos/o/r/issues/28/comments"),
        (.post, "/repos/o/r/pulls/29/reviews"),
        (.put, "/repos/o/r/pulls/29/merge"),
        (.patch, "/repos/o/r/pulls/29"),
    ])
    func refused(method: HTTPRequest.Method, path: String) async {
        #expect(await !Self.passes(method, path, through: Self.fence()))
    }

    @Test("another server is refused")
    func otherServer() async {
        let other = URL(string: "https://example.com")!
        #expect(await !Self.passes(.get, "/repos/o/r/pulls/29", through: Self.fence(), baseURL: other))
    }
}
