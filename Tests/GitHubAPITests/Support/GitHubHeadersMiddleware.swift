import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sends what every GitHub request needs: a User-Agent (GitHub rejects
/// requests without one), the pinned API version, and the token when there
/// is one.
///
/// The token goes in here, not in the generated client's input, because a
/// `ClientError` prints the request it was built from, every header included.
struct GitHubHeadersMiddleware: ClientMiddleware {
    let token: String?
    /// Replaces the generated `Accept: application/json`, to ask for one of
    /// GitHub's `+json` variants.
    var accept: String?

    @concurrent
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.userAgent] = "swift-steward-tests"
        request.headerFields[HTTPField.Name("x-github-api-version")!] = "2022-11-28"
        if let token {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        if let accept {
            request.headerFields[.accept] = accept
        }
        return try await next(request, body, baseURL)
    }
}
