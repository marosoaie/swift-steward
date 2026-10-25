/// Steward's summary comment on a pull request.
public struct SummaryComment: Sendable, Hashable, Identifiable {
    /// The host's identifier for a comment, unique within the host.
    public struct ID: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
        /// The host's number for the comment.
        public var rawValue: Int64

        /// Wraps the host's number for a comment.
        public init(rawValue: Int64) {
            self.rawValue = rawValue
        }

        /// The number, in decimal.
        public var description: String {
            String(rawValue)
        }
    }

    /// The comment's identifier, for updating or deleting it.
    public var id: ID
    /// The text as posted, without the host's marker.
    public var body: String
    /// The login of whoever posted it; nil when the account no longer exists.
    public var author: String?
    /// The comment's page on the host's website.
    public var webURL: String

    /// Creates a summary comment from its identifier, text, author, and page.
    public init(id: ID, body: String, author: String?, webURL: String) {
        self.id = id
        self.body = body
        self.author = author
        self.webURL = webURL
    }
}
