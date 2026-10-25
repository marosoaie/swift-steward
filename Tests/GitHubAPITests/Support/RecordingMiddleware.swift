import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Writes each response to `directory` as `<operation>.<scenario>.http`, the
/// fixture format, before the client decodes it, so a response that fails
/// to decode still leaves its evidence.
struct RecordingMiddleware: ClientMiddleware {
    let directory: URL
    let scenario: String

    @concurrent
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        let data = if let responseBody {
            try await Data(collecting: responseBody, upTo: 16 << 20)
        } else {
            Data()
        }
        let name = "\(operationID.replacingOccurrences(of: "/", with: "-")).\(scenario).http"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecordedResponse(response: response, body: data).encoded.write(to: directory.appendingPathComponent(name))
        return (response, responseBody.map { _ in HTTPBody(data) })
    }
}
