extension DecodingError {
    /// One line saying what's wrong and where, such as
    /// `pull_request.base.sha is missing`.
    var summary: String {
        switch self {
        case .keyNotFound(let key, let context):
            "\(Self.describe(context.codingPath + [key])) is missing"
        case .valueNotFound(_, let context):
            "\(Self.describe(context.codingPath)) is null"
        case .typeMismatch(let type, let context):
            "\(Self.describe(context.codingPath)) has the wrong type: expected \(type)"
        case .dataCorrupted(let context) where context.codingPath.isEmpty:
            context.debugDescription
        case .dataCorrupted(let context):
            "\(Self.describe(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            "\(self)"
        }
    }

    private static func describe(_ path: [any CodingKey]) -> String {
        path.isEmpty
            ? "the payload"
            : path.map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }.joined(separator: ".")
    }
}
