import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sends nothing: fails every request with the request it was handed, after
/// the middlewares, so a test can see exactly what would have gone out.
struct CapturingTransport: ClientTransport {
    struct Sent: Error {
        let request: HTTPRequest
    }

    @concurrent
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        throw Sent(request: request)
    }
}
