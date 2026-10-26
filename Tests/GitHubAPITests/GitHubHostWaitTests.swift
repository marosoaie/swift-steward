import Foundation
@testable import GitHubAPI
import HTTPTypes
import PullRequestHosting
import Testing

@Suite("GitHubHost says how long GitHub asks callers to wait")
struct GitHubHostWaitTests {
    // Regression (Codex review): the generated 403 for create-comment drops
    // its headers, so only RateLimitMiddleware can see the retry-after.
    @Test("issues/create-comment's declared 403 with a retry-after is a rate limit, whatever its message")
    func createThrottled() async throws {
        let message = "You have triggered an abuse detection mechanism. Please wait a few minutes."
        let response = try RecordedResponse(status: 403, headers: ["retry-after": "120"], json: ["message": message])
        let error = await GitHubHostErrorTests.hostError([response]) {
            _ = try await $0.createSummaryComment(onPullRequest: 21, body: "x")
        }
        #expect(error == PullRequestHostError(
            kind: .rateLimited,
            operation: "issues/create-comment",
            status: 403,
            message: message,
            retryAfter: .seconds(120)
        ))
    }

    /// A throttled answer's headers, and the wait they ask for.
    struct Throttle: Sendable, CustomTestStringConvertible {
        let headers: [String: String]
        let wait: Duration?

        var testDescription: String {
            "\(headers.sorted { $0.key < $1.key }) → \(wait.map(String.init(describing:)) ?? "nil")"
        }
    }

    static let now = Date(timeIntervalSince1970: 1_700_000_000.5)

    @Test("a throttled answer asks for its retry-after, or else the time left until its limit resets", arguments: [
        Throttle(headers: ["retry-after": "30"], wait: .seconds(30)),
        Throttle(headers: ["retry-after": "0"], wait: .zero),
        Throttle(
            headers: ["retry-after": "30", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1"],
            wait: .seconds(30)
        ),
        Throttle(headers: ["retry-after": "soon"], wait: nil),
        Throttle(headers: ["retry-after": "-5"], wait: nil),
        Throttle(headers: ["retry-after": "9999999999999"], wait: nil),
        Throttle(headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000090"], wait: .seconds(90)),
        Throttle(headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000001"], wait: .seconds(1)),
        Throttle(headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1699999000"], wait: .zero),
        Throttle(headers: ["x-ratelimit-remaining": "0"], wait: nil),
        Throttle(headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "later"], wait: nil),
    ])
    func retryAfter(_ throttle: Throttle) throws {
        let fields = try throttle.headers.map { name, value in
            HTTPField(name: try #require(HTTPField.Name(name)), value: value)
        }
        let response = HTTPResponse(status: .init(code: 403), headerFields: HTTPFields(fields))
        #expect(RateLimitMiddleware.retryAfter(response, now: Self.now) == throttle.wait)
    }

    @Test("the host's error carries the wait a throttled answer asks for, and none when only the message says so")
    func retryAfterThroughHost() async throws {
        let throttled = try RecordedResponse(status: 429, headers: ["retry-after": "7"], json: ["message": "Slow"])
        #expect(await GitHubHostErrorTests.hostError([throttled])?.retryAfter == .seconds(7))
        let unsaid = try RecordedResponse(status: 403, json: ["message": "API rate limit exceeded for user ID 1."])
        let error = await GitHubHostErrorTests.hostError([unsaid])
        #expect(error?.kind == .rateLimited)
        #expect(error?.retryAfter == nil)
    }

    // Regression (Codex review): only 403s and 429s kept their wait.
    @Test("a server error keeps the wait its retry-after asks for, and one without asks for none")
    func serverErrorWait() async throws {
        let unavailable = try RecordedResponse(status: 503, headers: ["retry-after": "120"], json: ["message": "Down"])
        #expect(await GitHubHostErrorTests.hostError([unavailable]) == PullRequestHostError(
            kind: .serverError,
            operation: "pulls/get",
            status: 503,
            message: "Down",
            retryAfter: .seconds(120)
        ))
        let failed = try RecordedResponse(status: 502, json: ["message": "Bad Gateway"])
        let error = await GitHubHostErrorTests.hostError([failed])
        #expect(error?.kind == .serverError)
        #expect(error?.retryAfter == nil)
    }
}
