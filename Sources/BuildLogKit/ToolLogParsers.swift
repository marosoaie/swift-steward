import Foundation

/// Parses `xcodebuild` / `swiftc` / clang build output.
///
/// Same line recognition as `ClangStyleLogParser`, plus extraction of the
/// clang warning flag when the message carries one:
///
///     src/main.c:7:9: warning: unused variable 'x' [-Wunused-variable]
///
/// becomes message `unused variable 'x'` with rule `-Wunused-variable`.
/// `-Werror`-promoted diagnostics carry a comma-separated flag list
/// (`[-Werror,-Wunused-variable]`); the last element — the specific flag —
/// becomes the rule. (swiftc diagnostics have no flags; those pass through
/// with a nil rule.)
public struct XcodeLogParser: LogParsing {
    private var base: ClangStyleLogParser

    /// Creates a parser that hasn't read anything yet.
    public init() {
        base = ClangStyleLogParser { diagnostic in
            var diagnostic = diagnostic
            // Flags can contain '#' (-W#warnings), '=' (GCC's -Wformat=),
            // etc. — accept anything up to the closing bracket rather than
            // enumerating characters. They never contain '['.
            if let (message, match) = splittingTrailingGroup(
                of: diagnostic.message,
                openingWith: "[",
                matching: /\[(?<flags>-W[^\]]+)\]/
            ) {
                diagnostic.rule = match.flags.split(separator: ",").last.map(String.init)
                diagnostic.message = message
            }
            return diagnostic
        }
    }

    /// Feeds the next chunk of the log; it may end mid-line.
    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        base.consume(chunk)
    }

    /// Flushes an unterminated final line and returns the diagnostics in
    /// log order.
    public mutating func finalize() -> [Diagnostic] {
        base.finalize()
    }
}

/// Parses SwiftLint's default (Xcode-style) reporter output:
///
///     /path/File.swift:10:5: warning: Line Length Violation: … (line_length)
///
/// The trailing parenthesized rule identifier is extracted into
/// `Diagnostic.rule` and stripped from the message.
public struct SwiftLintLogParser: LogParsing {
    private var base: ClangStyleLogParser

    /// Creates a parser that hasn't read anything yet.
    public init() {
        base = ClangStyleLogParser { diagnostic in
            var diagnostic = diagnostic
            // Built-in rule ids are snake_case, but custom rules
            // (custom_rules: in .swiftlint.yml) can be camelCase or
            // kebab-case; every violation line ends with the id, so the $
            // anchor alone bounds the match.
            if let (message, match) = splittingTrailingGroup(
                of: diagnostic.message,
                openingWith: "(",
                matching: /\((?<rule>[A-Za-z][A-Za-z0-9_-]*)\)/
            ) {
                diagnostic.rule = String(match.rule)
                diagnostic.message = message
            }
            return diagnostic
        }
    }

    /// Feeds the next chunk of the log; it may end mid-line.
    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        base.consume(chunk)
    }

    /// Flushes an unterminated final line and returns the diagnostics in
    /// log order.
    public mutating func finalize() -> [Diagnostic] {
        base.finalize()
    }
}

/// Parses `swiftformat --lint` output:
///
///     /path/File.swift:12:1: warning: (indent) Indent code in accordance …
///
/// The leading parenthesized rule name is extracted into `Diagnostic.rule`
/// and stripped from the message.
public struct SwiftFormatLogParser: LogParsing {
    private var base: ClangStyleLogParser

    /// Creates a parser that hasn't read anything yet.
    public init() {
        base = ClangStyleLogParser { diagnostic in
            var diagnostic = diagnostic
            if let match = diagnostic.message.firstMatch(of: /^\((?<rule>[A-Za-z][A-Za-z0-9_]*)\)\s*/) {
                diagnostic.rule = String(match.rule)
                diagnostic.message.removeSubrange(match.range)
            }
            return diagnostic
        }
    }

    /// Feeds the next chunk of the log; it may end mid-line.
    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        base.consume(chunk)
    }

    /// Flushes an unterminated final line and returns the diagnostics in
    /// log order.
    public mutating func finalize() -> [Diagnostic] {
        base.finalize()
    }
}

/// The message without its trailing group, the text from its last
/// `opening` on, when `group` matches all of that text, and without the
/// whitespace before the group; and the group's match.
///
/// Found from the end, not with a regex such as `\s*\[…\]$`: `firstMatch`
/// would try that from every character of a long run of spaces or of
/// repeated openings, each time scanning to the run's end, so a line's
/// time would grow with the square of its length.
private func splittingTrailingGroup<Output>(
    of message: String,
    openingWith opening: Character,
    matching group: Regex<Output>
) -> (message: String, match: Regex<Output>.Match)? {
    guard let start = message.lastIndex(of: opening),
          let match = message[start...].wholeMatch(of: group)
    else { return nil }
    let before = message[..<start]
    let end = before.lastIndex { !$0.isWhitespace }.map(before.index(after:)) ?? before.startIndex
    return (String(before[..<end]), match)
}
