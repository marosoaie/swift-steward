import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Fails every request with `error`, as a transport does when no response
/// arrives.
struct FailingTransport: ClientTransport {
    let error: any Error

    @concurrent
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        throw error
    }
}
