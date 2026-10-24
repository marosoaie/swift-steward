import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Answers every request with one recorded response, so the generated
/// client decodes it exactly as it would a live one.
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

/// Sends what every GitHub request needs: the token, the pinned API
/// version, and a User-Agent (GitHub rejects requests without one).
struct GitHubHeadersMiddleware: ClientMiddleware {
    let token: String?
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
        request.headerFields[.userAgent] = "swift-steward-spike"
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

/// Writes each response to `directory` as `<operation>.<scenario>.http`
/// before the client decodes it, so a decoding failure still leaves the
/// response that caused it.
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
        var data = Data()
        if let responseBody {
            data = try await Data(collecting: responseBody, upTo: 16 << 20)
        }
        let name = "\(operationID.replacingOccurrences(of: "/", with: "-")).\(scenario).http"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecordedResponse(response: response, body: data).encoded
            .write(to: directory.appendingPathComponent(name))
        return (response, HTTPBody(data))
    }
}
