@testable import Steward
import Testing

/// `Markdown.escaped` against GitHub's issue references, which GitHub finds
/// in the rendered text, as it finds mentions. Which spellings GitHub links
/// was checked with `gh api markdown`, in GFM mode with a repository as
/// context.
@Suite("Escaped text and issue references")
struct MarkdownReferenceTests {
    @Test("a zero-width space between an issue number and its # or GH- keeps it from linking", arguments: [
        ("#12", "#\u{200B}12"),
        ("see #1.", "see #\u{200B}1."),
        ("(#7)", "(#\u{200B}7)"),
        ("##1", "##\u{200B}1"),
        ("owner/repo#12", "owner/repo#\u{200B}12"),
        ("GH-12", "GH-\u{200B}12"),
        ("gh-1 and Gh-2", "gh-\u{200B}1 and Gh-\u{200B}2"),
        ("x/GH-1, .GH-2", "x/GH-\u{200B}1, .GH-\u{200B}2"),
        ("**#1**", "\\*\\*#\u{200B}1\\*\\*"),
        ("https://example.com/page#3", "https://example.com/page#\u{200B}3"),
    ])
    func brokenReferences(text: String, escaped: String) {
        #expect(Markdown.escaped(text) == escaped)
    }

    @Test("text GitHub doesn't link is left as it is", arguments: [
        "#if DEBUG", "#available(iOS 17, macOS 26)", "#selector(tap)", "# heading", "#", "ends with #",
        "#a1", "#１", "#١", "GH-", "GH-x", "GH--1", "fooGH-1", "high-5", "-1", "a-1",
    ])
    func unlinkedText(text: String) {
        #expect(Markdown.escaped(text) == text)
    }

    @Test("after an underscore, GH- is inside a word, so only the underscore is escaped")
    func underscoreBeforeGH() {
        #expect(Markdown.escaped("_GH-1") == "\\_GH-1")
    }
}
