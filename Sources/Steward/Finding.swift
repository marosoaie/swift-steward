/// One thing a rule wants the pull request's author to see.
///
/// Rules return findings; the runner collects them into a `Report`, in
/// rule order, and renders them into the summary.
///
/// ```swift
/// Rule("Changelog") { context in
///     guard !context.git.modifiedFiles.contains("CHANGELOG.md") else { return [] }
///     return [.warning("Add a CHANGELOG entry.")]
/// }
/// ```
public struct Finding: Sendable, Hashable, Codable {
    /// How a finding counts: failures fail the check, the other kinds only
    /// inform.
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Fails the check: the run exits with status 1.
        case failure
        /// Worth fixing, but doesn't fail the check.
        case warning
        /// For information.
        case message
        /// Free-form Markdown, shown as it is below the tables, for lists,
        /// code blocks, or tables of a rule's own.
        case markdown
    }

    /// How the finding counts.
    public var kind: Kind
    /// What to tell the author, as GitHub-flavored Markdown.
    ///
    /// Failures, warnings, and messages are shown in table cells, which
    /// can't hold block Markdown: line breaks become `<br>`. A rule that
    /// needs a list or a code block returns a `markdown` finding instead.
    public var text: String
    /// Where in the head commit the finding is: a file, and optionally a
    /// line; nil for the pull request as a whole. The summary links to it.
    public var location: Location?
    /// The name of the rule that returned the finding. The runner sets it,
    /// replacing whatever a rule put there.
    public var rule: String?

    /// Creates a finding from its parts.
    public init(kind: Kind, text: String, location: Location? = nil, rule: String? = nil) {
        self.kind = kind
        self.text = text
        self.location = location
        self.rule = rule
    }

    /// A finding that fails the check, as danger-swift's `fail`.
    public static func failure(_ text: String, at location: Location? = nil) -> Finding {
        Finding(kind: .failure, text: text, location: location)
    }

    /// A finding that warns without failing the check, as danger-swift's
    /// `warn`.
    public static func warning(_ text: String, at location: Location? = nil) -> Finding {
        Finding(kind: .warning, text: text, location: location)
    }

    /// A finding for information, as danger-swift's `message`.
    public static func message(_ text: String, at location: Location? = nil) -> Finding {
        Finding(kind: .message, text: text, location: location)
    }

    /// Free-form Markdown shown as it is, as danger-swift's `markdown`.
    ///
    /// The summary shows a location's link on its own line below the text.
    public static func markdown(_ text: String, at location: Location? = nil) -> Finding {
        Finding(kind: .markdown, text: text, location: location)
    }

    /// The report's JSON keys, a wire contract (docs/danger.md, section 4).
    enum CodingKeys: String, CodingKey {
        case kind
        case text
        case location
        case rule
    }
}
