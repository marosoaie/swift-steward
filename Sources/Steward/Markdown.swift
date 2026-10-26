import Foundation

/// Building blocks for the GitHub-flavored Markdown the summary is made of.
enum Markdown {
    /// `text`, plain text such as an error's description, escaped so it
    /// renders as written inside a line: Markdown's inline punctuation is
    /// backslash-escaped, and every `@` is followed by a zero-width space,
    /// so a message can't mention anyone. (GitHub still turns `\@name` into
    /// a mention: it finds mentions in the rendered text.)
    static func escaped(_ text: String) -> String {
        String(text.unicodeScalars.flatMap { scalar -> [Unicode.Scalar] in
            if scalar == "@" { return ["@", "\u{200B}"] }
            return inlinePunctuation.contains(scalar) ? ["\\", scalar] : [scalar]
        }.map(Character.init))
    }

    private static let inlinePunctuation: Set<Unicode.Scalar> = ["\\", "`", "*", "_", "[", "]", "<", ">", "&", "~"]

    /// `text` as the content of a table cell: `|` escaped and line breaks
    /// as `<br>`, so cells joined with `<br>` stay cells.
    ///
    /// GitHub's table parser turns every `\|` back into `|` before it reads
    /// the cell's Markdown, so the cell renders as `text` would on its own,
    /// a `\|` the text already had included. Pipes are found by scalar: a
    /// `|` followed by a combining mark is one `Character`, but the parser
    /// still splits the row at it. A backslash would escape the `<` of a
    /// `<br>` after it, so one before a line break, Markdown's hard break,
    /// is dropped for the `<br>` that stands in for it, and one that ends
    /// the text, a literal backslash, is doubled.
    static func tableCell(_ text: String) -> String {
        let lines = lines(of: text)
        return zip(lines.indices, lines).map { index, line in
            let scalars = line.unicodeScalars
            let isLast = index == lines.count - 1
            let endsInEscape = scalars.reversed().prefix { $0 == "\\" }.count % 2 == 1
            let kept = endsInEscape && !isLast ? scalars.dropLast() : scalars[...]
            let escaped = kept.flatMap { scalar -> [Unicode.Scalar] in scalar == "|" ? ["\\", "|"] : [scalar] }
            return String((escaped + (endsInEscape && isLast ? ["\\"] : [])).map(Character.init))
        }.joined(separator: "<br>")
    }

    /// `text` as a code span, which shows it verbatim: fenced by one more
    /// backtick than its longest run of them, and padded with spaces when
    /// it starts or ends with a backtick or a space, which the fence would
    /// otherwise swallow. Line breaks become spaces, as a code span shows
    /// them anyway, so the span can sit in a table cell. Backticks are
    /// counted by scalar, as the Markdown parser counts them, so one
    /// followed by a combining mark still counts.
    static func codeSpan(_ text: String) -> String {
        let content = lines(of: text).joined(separator: " ")
        let scalars = content.unicodeScalars
        let longestRun = scalars.split { $0 != "`" }.map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: longestRun + 1)
        let needsPadding = scalars.first.map { $0 == "`" || $0 == " " } == true
            || scalars.last.map { $0 == "`" || $0 == " " } == true
        let padding = needsPadding ? " " : ""
        return fence + padding + content + padding + fence
    }

    /// `segment` with every byte that isn't an unreserved URL character
    /// (`A–Z a–z 0–9 - . _ ~`) percent-encoded, so it can sit between two
    /// `/` of a link's path.
    static func percentEncoded(_ segment: String) -> String {
        segment.utf8.map { byte in
            isUnreserved(byte) ? String(UnicodeScalar(byte)) : "%" + hexDigits(of: byte)
        }.joined()
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || [UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~")].contains(byte)
    }

    private static func hexDigits(of byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }

    /// The lines of `text`, split at `\r\n`, `\n`, and `\r`, so a trailing
    /// line break gives a trailing empty line.
    private static func lines(of text: String) -> [Substring] {
        // `\r\n` is one Character, so splitting on Characters keeps it whole.
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
    }
}
