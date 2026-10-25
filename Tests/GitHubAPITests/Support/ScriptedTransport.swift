import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Answers requests with a script of recorded responses, one per request in
/// order, and keeps every request it was sent, so a test can replay a whole
/// exchange and check what went out.
///
/// An actor, not a struct: the requests arrive through a `Sendable`
/// protocol, and `Mutex` needs macOS 15, above the package's floor.
actor ScriptedTransport: ClientTransport {
    /// A request as it reached the transport, after the middlewares.
    struct Sent: Sendable {
        let operationID: String
        let baseURL: URL
        let method: HTTPRequest.Method
        /// Without the query.
        let path: String
        let query: [String: String]
        let headers: HTTPFields
        let body: Data

        /// The request body's `body` member, for the comment operations.
        var commentText: String? {
            (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["body"] as? String
        }
    }

    struct ScriptExhausted: Error {
        let operationID: String
    }

    private var script: [RecordedResponse]
    private(set) var sent: [Sent] = []

    init(_ script: [RecordedResponse]) {
        self.script = script
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let data = if let body {
            try await Data(collecting: body, upTo: 1 << 20)
        } else {
            Data()
        }
        let components = URLComponents(string: request.path ?? "")
        sent.append(Sent(
            operationID: operationID,
            baseURL: baseURL,
            method: request.method,
            path: components?.path ?? "",
            query: Dictionary(
                (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                uniquingKeysWith: { _, last in last }
            ),
            headers: request.headerFields,
            body: data
        ))
        guard !script.isEmpty else {
            throw ScriptExhausted(operationID: operationID)
        }
        let next = script.removeFirst()
        return (next.response, HTTPBody(next.body))
    }
}
