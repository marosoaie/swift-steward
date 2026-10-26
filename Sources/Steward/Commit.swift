import Foundation

/// One of a pull request's commits, as `git log` reads it from the local
/// checkout.
public struct Commit: Sendable, Hashable {
    /// Who wrote or committed a commit, and when, as the commit records it
    /// (without `.mailmap` applied).
    public struct Signature: Sendable, Hashable {
        /// The name.
        public var name: String
        /// The email address.
        public var email: String
        /// The time; the commit's time zone isn't kept.
        public var date: Date

        /// Creates a signature from its parts.
        public init(name: String, email: String, date: Date) {
            self.name = name
            self.email = email
            self.date = date
        }
    }

    /// The commit's full SHA.
    public var sha: String
    /// The parents' full SHAs: none for a root commit, two or more for a
    /// merge.
    public var parents: [String]
    /// Who wrote the change.
    public var author: Signature
    /// Who committed it, for example when rebasing or applying a patch.
    public var committer: Signature
    /// The message's first paragraph, its lines joined by spaces (git's
    /// `%s`).
    public var subject: String
    /// The rest of the message, after the blank line that ends the
    /// subject (git's `%b`), without trailing newlines; empty when there
    /// is none.
    public var body: String

    /// Creates a commit from its parts.
    public init(
        sha: String,
        parents: [String],
        author: Signature,
        committer: Signature,
        subject: String,
        body: String
    ) {
        self.sha = sha
        self.parents = parents
        self.author = author
        self.committer = committer
        self.subject = subject
        self.body = body
    }
}
