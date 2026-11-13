/// A path pattern in git's `:(glob)` pathspec dialect, anchored at the
/// repository's root: what `Rule.group(whenChangesMatch:_:)` and
/// `GitChanges.changes(matching:)` take.
///
/// `*` matches any run of characters within one path component, `?` one
/// byte, and `**` as a whole component any number of directories:
/// `Sources/*` matches the files directly in `Sources`, `**/*.swift` every
/// Swift file, and `mbk/**` everything under `mbk`. A pattern without
/// wildcards matches that file and everything under that directory.
///
/// A pattern matches exactly the paths `git ls-files ':(glob)<pattern>'`
/// lists, compared as git's bytes: matching is case-sensitive, and `?`
/// matches one byte of a multibyte character, not the character.
///
/// The dialect is a subset of git's: `[...]` classes aren't supported yet,
/// so a literal `[` is written `\[`, and `\` escapes any character. A
/// malformed pattern doesn't trap: whatever uses it throws an error that
/// names it and says what's wrong. Malformed are an empty pattern (`**`
/// matches every file), a leading `/`, an empty, `.` or `..` component, an
/// unescaped `[`, a trailing `\`, and a `**` that isn't a whole component,
/// such as `Sources**`.
public struct PathPattern: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The pattern as written.
    public var description: String

    /// Creates a pattern from its text, which is checked only where the
    /// pattern is used.
    public init(_ pattern: String) {
        description = pattern
    }

    /// Creates a pattern from a string literal, such as `"mbk/**"`.
    public init(stringLiteral pattern: String) {
        self.init(pattern)
    }
}
