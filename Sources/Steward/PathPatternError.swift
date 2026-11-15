/// A `PathPattern` that can't be matched: what `GitChanges.changes(matching:)`
/// throws for it, and what a rule in a group that uses it fails with.
///
/// `kind` says what's wrong, and `description` says it in a sentence that
/// names the pattern.
public struct PathPatternError: Error, Sendable, Hashable, CustomStringConvertible {
    /// What's wrong with a pattern.
    ///
    /// Minor releases may add cases, so a `switch` over one needs an
    /// `@unknown default`.
    #if hasAttribute(nonexhaustive)
    @nonexhaustive
    #endif
    public enum Kind: Sendable, Hashable {
        /// The pattern is empty; `**` matches every file.
        case empty
        /// The pattern starts with `/`; patterns start at the repository's
        /// root without one.
        case leadingSlash
        /// An empty, `.` or `..` component, which git would rewrite away.
        case invalidComponent(String)
        /// An unescaped `[`. Classes aren't supported yet, so a literal
        /// `[` is written `\[`; once they are, this kind may be retired.
        case unescapedBracket
        /// A final `\` that escapes nothing.
        case trailingBackslash
        /// A `**` with something other than `/` or an end on either side,
        /// such as `Sources**`.
        case partialGlobstar
        /// A pattern that ends in `/` and has a `*`, `?` or `\`, such as
        /// `Sources/*/`. Git matches it only as written, so it matches
        /// only a directory whose name holds those characters; adding `**`
        /// gives what it means.
        case nonliteralDirectory
    }

    /// The pattern, as written.
    public let pattern: PathPattern

    /// What's wrong with it.
    public let kind: Kind

    /// Creates the error for `pattern`.
    public init(pattern: PathPattern, kind: Kind) {
        self.pattern = pattern
        self.kind = kind
    }

    /// What's wrong, in a sentence that names the pattern and says how to
    /// write it instead.
    public var description: String {
        switch kind {
        case .empty:
            "The path pattern is empty; write ** for every file."
        case .leadingSlash:
            "The path pattern “\(pattern)” starts with “/”; patterns start at the repository's root without one."
        case .invalidComponent(""):
            "The path pattern “\(pattern)” has an empty component."
        case .invalidComponent(let component):
            "The path pattern “\(pattern)” has a “\(component)” component; write the path without it."
        case .unescapedBracket:
            """
            The path pattern “\(pattern)” has an unescaped “[”; classes aren't supported, \
            so write \\[ for a literal one.
            """
        case .trailingBackslash:
            "The path pattern “\(pattern)” ends with a “\\” that escapes nothing."
        case .partialGlobstar:
            """
            The path pattern “\(pattern)” has a “**” that isn't a whole component, as in a/**/b; \
            use * within a component.
            """
        case .nonliteralDirectory:
            """
            The path pattern “\(pattern)” ends with “/” and has a “*”, “?” or “\\”, so git matches it \
            only as written; write \(pattern)** for the files under the directories it names.
            """
        }
    }
}
