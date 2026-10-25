import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Refuses every request but a GET before it leaves the process, so the live
/// tests can't create or change anything on GitHub, whatever a test calls.
struct ReadOnlyMiddleware: ClientMiddleware {
    struct Refusal: Error, CustomStringConvertible {
        let method: HTTPRequest.Method
        let operationID: String

        var description: String {
            "the live tests are read-only: refused \(method.rawValue) for \(operationID)"
        }
    }

    @concurrent
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard request.method == .get else {
            throw Refusal(method: request.method, operationID: operationID)
        }
        return try await next(request, body, baseURL)
    }
}
