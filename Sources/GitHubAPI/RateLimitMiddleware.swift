import Foundation
import HTTPTypes
import OpenAPIRuntime
import PullRequestHosting

/// Fails a request GitHub throttled as `.rateLimited`, before the client
/// decodes the response: a 403 or 429 with `x-ratelimit-remaining: 0` (the
/// primary limit) or a `retry-after` (secondary limits and abuse
/// detection), whatever its message says.
///
/// A middleware because only it sees the headers of every response: the
/// generated client drops them for declared statuses, such as
/// issues/create-comment's 403.
struct RateLimitMiddleware: ClientMiddleware {
    private static let remainingField = HTTPField.Name("x-ratelimit-remaining")
    private static let retryAfterField = HTTPField.Name("retry-after")

    static func isThrottled(_ response: HTTPResponse) -> Bool {
        let headers = response.headerFields
        return [403, 429].contains(response.status.code)
            && (remainingField.flatMap { headers[$0] } == "0" || retryAfterField.flatMap { headers[$0] } != nil)
    }

    @concurrent
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard Self.isThrottled(response) else {
            return (response, responseBody)
        }
        throw await PullRequestHostError(
            kind: .rateLimited,
            operation: operationID,
            status: response.status.code,
            message: PullRequestHostError.message(in: responseBody)
        )
    }
}
