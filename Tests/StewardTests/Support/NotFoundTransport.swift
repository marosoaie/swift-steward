import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Answers every request with 404 Not Found.
struct NotFoundTransport: ClientTransport {
    @concurrent
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var fields = HTTPFields()
        fields[.contentType] = "application/json; charset=utf-8"
        return (HTTPResponse(status: .notFound, headerFields: fields), HTTPBody(#"{"message":"Not Found"}"#))
    }
}
