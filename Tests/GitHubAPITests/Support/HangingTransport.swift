import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Waits until its task is cancelled, then fails the way URLSession does:
/// with `URLError(.cancelled)`, not a `CancellationError`.
struct HangingTransport: ClientTransport {
    @concurrent
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try? await Task.sleep(for: .seconds(60))
        throw URLError(.cancelled)
    }
}
