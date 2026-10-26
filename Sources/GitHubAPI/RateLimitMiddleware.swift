import Foundation
import HTTPTypes
import OpenAPIRuntime
import PullRequestHosting

/// Fails a request GitHub throttled as `.rateLimited`, before the client
/// decodes the response: a 403 or 429 with `x-ratelimit-remaining: 0` (the
/// primary limit) or a `retry-after` (secondary limits and abuse
/// detection), whatever its message says. A server error with a
/// `retry-after`, such as a 503 during maintenance, fails here too, as
/// `.serverError`, so that its wait isn't lost.
///
/// The error's `retryAfter` is what GitHub asks callers to wait: the
/// `retry-after` seconds, or else, for the primary limit, the time left
/// until `x-ratelimit-reset`.
///
/// A middleware because only it sees the headers of every response: the
/// generated client drops them for declared statuses, such as
/// issues/create-comment's 403.
struct RateLimitMiddleware: ClientMiddleware {
    private static let remainingField = HTTPField.Name("x-ratelimit-remaining")
    private static let resetField = HTTPField.Name("x-ratelimit-reset")
    private static let retryAfterField = HTTPField.Name("retry-after")

    /// The current time, which `x-ratelimit-reset` is compared with.
    var now: @Sendable () -> Date = { Date() }

    static func isThrottled(_ response: HTTPResponse) -> Bool {
        let headers = response.headerFields
        return [403, 429].contains(response.status.code)
            && (remainingField.flatMap { headers[$0] } == "0" || retryAfterField.flatMap { headers[$0] } != nil)
    }

    /// Whether `response` is a server error that says when to try again.
    static func isUnavailable(_ response: HTTPResponse) -> Bool {
        response.status.kind == .serverError && retryAfterField.flatMap { response.headerFields[$0] } != nil
    }

    /// How long a throttled response asks callers to wait, or nil when it
    /// doesn't say in a form GitHub documents: whole seconds in
    /// `retry-after`, a Unix time in `x-ratelimit-reset`.
    static func retryAfter(_ response: HTTPResponse, now: Date) -> Duration? {
        let headers = response.headerFields
        if let value = retryAfterField.flatMap({ headers[$0] }) {
            return wholeSeconds(value).map { .seconds($0) }
        }
        guard remainingField.flatMap({ headers[$0] }) == "0",
              let reset = resetField.flatMap({ headers[$0] }).flatMap(wholeSeconds)
        else { return nil }
        // A reset already past, by this clock, asks for no wait.
        return .seconds(max(0, (Double(reset) - now.timeIntervalSince1970).rounded(.up)))
    }

    /// `value` as a count of whole seconds: digits only, short enough not
    /// to overflow.
    private static func wholeSeconds(_ value: String) -> Int64? {
        let digits = value.utf8
        guard (1...12).contains(digits.count),
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int64(value)
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
        let kind: PullRequestHostError.Kind? = if Self.isThrottled(response) {
            .rateLimited
        } else if Self.isUnavailable(response) {
            .serverError
        } else {
            nil
        }
        guard let kind else { return (response, responseBody) }
        throw await PullRequestHostError(
            kind: kind,
            operation: operationID,
            status: response.status.code,
            message: PullRequestHostError.message(in: responseBody),
            retryAfter: Self.retryAfter(response, now: now())
        )
    }
}
