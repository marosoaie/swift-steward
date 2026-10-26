import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

/// Fails the test on any request, for runs that must not reach the network.
struct ForbiddenTransport: ClientTransport {
    struct Refused: Error {}

    @concurrent
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        Issue.record("\(request.method) \(request.path ?? "") went out from a run that must make no request")
        throw Refused()
    }
}
