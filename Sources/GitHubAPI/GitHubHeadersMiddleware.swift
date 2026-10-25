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
    /// The version `Specs/github/upstream.env` pins.
    static let apiVersion = "2022-11-28"
    // Never nil, since the name is a valid token: HTTPField.Name has only a
    // failable initializer, and this target allows no force unwraps.
    private static let apiVersionField = HTTPField.Name("x-github-api-version")

    let credential: Credential?
    /// Replaces the generated `Accept: application/json`, to ask for one of
    /// GitHub's `+json` variants.
    let accept: String?

    init(token: String?, accept: String? = nil) {
        credential = token.map(Credential.init)
        self.accept = accept
    }

    @concurrent
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.userAgent] = "swift-steward"
        if let field = Self.apiVersionField {
            request.headerFields[field] = Self.apiVersion
        }
        if let credential {
            request.headerFields[.authorization] = "Bearer \(credential.token)"
        }
        if let accept {
            request.headerFields[.accept] = accept
        }
        return try await next(request, body, baseURL)
    }
}
