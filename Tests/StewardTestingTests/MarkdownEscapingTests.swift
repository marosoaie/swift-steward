import StewardTesting
import Testing

/// Steward's escaping as a rule outside the package calls it: on text from
/// the pull request, here a file's name.
@Suite("Escaping pull request text in a rule")
struct MarkdownEscapingTests {
    static let createdFiles = Rule("Created files") { context in
        context.git.createdFiles.map { path in
            .message("Created \(Markdown.codeSpan(path)), \(Markdown.escaped(path))", at: Location(path: path))
        }
    }

    @Test("a file name shows as written, as code and as text, and mentions no one")
    func createdFileName() async throws {
        let path = "@team_*notes*`#12.md"
        let context = try Context.fixture(diff: """
            diff --git a/\(path) b/\(path)
            new file mode 100644
            --- /dev/null
            +++ b/\(path)
            @@ -0,0 +1 @@
            +notes
            """)
        let findings = try await Self.createdFiles.evaluate(context)
        #expect(findings.map(\.text) == [
            "Created ``@team_*notes*`#12.md``, @\u{200B}team\\_\\*notes\\*\\`#\u{200B}12.md",
        ])
    }
}
