@testable import Steward
import Testing

@Suite("Markdown building blocks")
struct MarkdownTests {
    @Test("plain text has its inline punctuation escaped and can't mention anyone")
    func escaping() {
        #expect(Markdown.escaped(#"a*b_c`d[e](f) <g> & ~h~ \i"#) == #"a\*b\_c\`d\[e\](f) \<g\> \& \~h\~ \\i"#)
        #expect(Markdown.escaped("ping @ada, mail ada@example.com")
            == "ping @\u{200B}ada, mail ada@\u{200B}example.com")
        #expect(Markdown.escaped("Plain text, 1.0: done!") == "Plain text, 1.0: done!")
    }

    @Test("a table cell escapes pipes and turns every kind of line break into <br>")
    func tableCell() {
        #expect(Markdown.tableCell("a|b\nc\r\nd\re\n") == #"a\|b<br>c<br>d<br>e<br>"#)
        #expect(Markdown.tableCell(#"already \| escaped"#) == #"already \\| escaped"#)
        #expect(Markdown.tableCell("").isEmpty)
        // One Character, two scalars: GitHub still splits the row there.
        #expect(Markdown.tableCell("a|\u{301}b") == "a\\|\u{301}b")
    }

    @Test("a table cell keeps a backslash from escaping the <br> after it, a hard break's or a literal one's")
    func tableCellBackslashes() {
        // GitHub renders `first\<br>second` as the text `first<br>second`.
        #expect(Markdown.tableCell(#"hard\"# + "\nbreak") == "hard<br>break")
        #expect(Markdown.tableCell(#"escaped \\"# + "\nbackslash") == #"escaped \\<br>backslash"#)
        #expect(Markdown.tableCell(#"three \\\"# + "\nbackslashes") == #"three \\<br>backslashes"#)
        #expect(Markdown.tableCell(#"ends in \"#) == #"ends in \\"#)
        #expect(Markdown.tableCell(#"ends in \\"#) == #"ends in \\"#)
    }

    @Test("a code span fences past the text's backticks and keeps its edges", arguments: [
        ["Sources/App.swift", "`Sources/App.swift`"],
        ["a`b", "``a`b``"],
        ["``x", "``` ``x ```"],
        [" x", "`  x `"],
        ["two\nlines", "`two lines`"],
        ["", "``"],
        // A backtick and a combining mark are one Character, but a backtick
        // to the Markdown parser.
        ["a`\u{301}b", "``a`\u{301}b``"],
        ["`\u{301}x", "`` `\u{301}x ``"],
    ])
    func codeSpan(pair: [String]) {
        #expect(Markdown.codeSpan(pair[0]) == pair[1])
    }

    @Test("a URL path segment keeps only unreserved characters unencoded")
    func percentEncoding() {
        #expect(Markdown.percentEncoded("A-z_0.9~") == "A-z_0.9~")
        #expect(Markdown.percentEncoded("a b#c?d%e|f") == "a%20b%23c%3Fd%25e%7Cf")
        #expect(Markdown.percentEncoded("Ün") == "%C3%9Cn")
    }
}
