/// A host failed or refused a request.
///
/// `kind` says what a caller can do about it, and `retryAfter` when it may
/// try again; `status` and `message` say what the host answered, for the
/// log.
public struct PullRequestHostError: Error, Sendable, Hashable, CustomStringConvertible {
    /// What went wrong, in the terms a caller acts on.
    public enum Kind: Sendable, Hashable {
        /// The pull request, comment, or repository doesn't exist, or the
        /// credentials can't see it (hosts hide private repositories that
        /// way).
        case notFound
        /// The credentials are missing, wrong, or expired.
        case unauthorized
        /// The credentials are valid but lack the permission, for example a
        /// workflow token without `pull-requests: write`.
        case forbidden
        /// A rate limit ran out; retrying later can succeed.
        case rateLimited
        /// The host refused the request's content, for example a comment
        /// longer than it accepts.
        case rejected
        /// The host failed on its side.
        case serverError
        /// The host answered a status nothing above covers.
        case unexpectedStatus
        /// No response arrived: the connection failed or timed out.
        case network
        /// A response arrived, but not in the shape the host promises.
        case malformedResponse
    }

    /// What went wrong.
    public var kind: Kind
    /// The request that failed, for example `issues/update-comment`.
    public var operation: String
    /// The HTTP status, when a response arrived.
    public var status: Int?
    /// The host's explanation, such as "Bad credentials", or the cause when
    /// no usable response arrived.
    public var message: String?
    /// How long the host asked callers to wait before trying again, when it
    /// said; nil when it didn't. Set for some `rateLimited` and
    /// `serverError` errors.
    public var retryAfter: Duration?

    /// Creates an error from what went wrong and what the host answered.
    public init(
        kind: Kind,
        operation: String,
        status: Int? = nil,
        message: String? = nil,
        retryAfter: Duration? = nil
    ) {
        self.kind = kind
        self.operation = operation
        self.status = status
        self.message = message
        self.retryAfter = retryAfter
    }

    /// The operation, the status, and the message, on one line.
    public var description: String {
        let answer = [status.map { "HTTP \($0)" }, message].compactMap(\.self).joined(separator: ": ")
        return answer.isEmpty ? "\(operation) failed (\(kind))" : "\(operation) failed (\(kind)): \(answer)"
    }
}
