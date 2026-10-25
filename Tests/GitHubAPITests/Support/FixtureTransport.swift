import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Answers every request with one recorded response, so the generated client
/// decodes it through its real path: status dispatch, content-type check,
/// and JSON decoding.
struct FixtureTransport: ClientTransport {
    let recorded: RecordedResponse

    @concurrent
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        (recorded.response, HTTPBody(recorded.body))
    }
}
