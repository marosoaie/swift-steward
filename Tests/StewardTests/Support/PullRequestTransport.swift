import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

/// Answers `GET <path>` with a recorded `pulls/get` body, and fails the test
/// on any other request, or one without the expected token.
struct PullRequestTransport: ClientTransport {
    /// The request path to answer, such as `/repos/o/r/pulls/26`.
    let path: String
    /// The `Authorization` header the request must carry; nil for none.
    let authorization: String?
    let body: Data

    /// A transport answering `pulls/get` for `owner/repository#number` with
    /// the response recorded as Fixtures/pulls/`fixture`.json.
    init(owner: String, repository: String, number: Int, fixture: String, token: String?) throws {
        guard let url = Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures/pulls")
        else { throw FixtureError("no fixture Fixtures/pulls/\(fixture).json") }
        path = "/repos/\(owner)/\(repository)/pulls/\(number)"
        authorization = token.map { "Bearer \($0)" }
        body = try Data(contentsOf: url)
    }

    @concurrent
    func send(
        _ request: HTTPRequest,
        body requestBody: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard request.method == .get, request.path == path else {
            Issue.record("\(request.method) \(request.path ?? "") went out; only GET \(path) may")
            return (HTTPResponse(status: .notFound), nil)
        }
        #expect(request.headerFields[.authorization] == authorization)
        var fields = HTTPFields()
        fields[.contentType] = "application/json; charset=utf-8"
        return (HTTPResponse(status: .ok, headerFields: fields), HTTPBody(body))
    }
}
