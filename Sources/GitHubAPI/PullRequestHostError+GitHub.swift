import Foundation
import HTTPTypes
import OpenAPIRuntime
import PullRequestHosting

extension PullRequestHostError {
    /// How much of an undocumented response's body is read for its message.
    /// GitHub's error bodies are a few hundred bytes.
    static let maximumErrorBodySize = 64 << 10

    /// The kind GitHub means by `status`.
    ///
    /// GitHub signals an exhausted rate limit with a 429, or with a 403 that
    /// says so in its message ("API rate limit exceeded…", "You have
    /// exceeded a secondary rate limit…") or in its headers. The headers are
    /// `RateLimitMiddleware`'s to read, since the generated responses drop
    /// them for declared statuses.
    static func kind(status: Int, message: String?) -> Kind {
        switch status {
        case 401:
            .unauthorized
        case 403 where message?.lowercased().contains("rate limit") == true:
            .rateLimited
        case 403:
            .forbidden
        // 410: the repository has issues, and with them issue comments,
        // turned off.
        case 404, 410:
            .notFound
        case 422:
            .rejected
        case 429:
            .rateLimited
        case 500...599:
            .serverError
        default:
            .unexpectedStatus
        }
    }

    /// An error response the description declares, with the message from
    /// its body.
    init(operation: String, status: Int, message: String?) {
        self.init(
            kind: Self.kind(status: status, message: message),
            operation: operation,
            status: status,
            message: message
        )
    }

    /// A response the description doesn't declare, such as any 401. Reads
    /// the message from the body when it's GitHub's usual error JSON.
    init(operation: String, status: Int, undocumented payload: UndocumentedPayload) async {
        let message = await Self.message(in: payload.body)
        self.init(
            kind: Self.kind(status: status, message: message),
            operation: operation,
            status: status,
            message: message
        )
    }

    /// A failure the generated client threw: no response, or a response it
    /// couldn't decode.
    init(operation: String, clientError: ClientError) {
        guard let response = clientError.response else {
            self.init(kind: .network, operation: operation, message: String(describing: clientError.underlyingError))
            return
        }
        let status = response.status.code
        // An error status with an unexpected body still says what happened;
        // only a success that doesn't decode is malformed.
        guard response.status.kind == .successful else {
            self.init(
                kind: Self.kind(status: status, message: nil),
                operation: operation,
                status: status
            )
            return
        }
        self.init(
            kind: .malformedResponse,
            operation: operation,
            status: status,
            message: String(describing: clientError.underlyingError)
        )
    }

    private struct ErrorBody: Decodable {
        let message: String?
    }

    /// The `message` of GitHub's error JSON in `body`, if that's what it
    /// holds.
    static func message(in body: HTTPBody?) async -> String? {
        guard let body, let data = try? await Data(collecting: body, upTo: maximumErrorBodySize) else {
            return nil
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
    }
}
