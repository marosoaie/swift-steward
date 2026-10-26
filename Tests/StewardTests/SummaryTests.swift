import Foundation
@testable import Steward
import Testing

@Suite("The summary")
struct SummaryTests {
    static let head = Context.stubHead
    static let server = URL(string: "https://github.com")!
    static let run = Summary.Origin.workflowRun(URL(string: "https://github.com/o/r/actions/runs/123")!)

    static func summary(
        _ findings: [Finding],
        repository: String = "o/r",
        origin: Summary.Origin = run,
        unlinkedPaths: Set<String> = []
    ) -> String {
        Summary(
            report: Report(
                repository: repository,
                pullRequest: 7,
                headCommit: head,
                findings: findings,
                generator: "Steward"
            ),
            serverURL: server,
            origin: origin,
            unlinkedPaths: unlinkedPaths
        ).text
    }

    @Test("docs/danger.md's example renders exactly as the document shows it")
    func documentedExample() throws {
        let document = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../docs/danger.md"),
            encoding: .utf8
        )
        let section = try #require(document.components(separatedBy: "### What it says").dropFirst().first)
        let block = try #require(section.components(separatedBy: "```markdown\n").dropFirst().first?
            .components(separatedBy: "```").first)
        let expected = block.replacingOccurrences(of: "4c95447…", with: Self.head)
        let findings: [Finding] = [
            .failure("Write Legacy.m in Swift.", at: Location(path: "Sources/Legacy.m")),
            .failure("Unused variable 'count'.", at: Location(path: "Sources/Counter.swift", line: 12)),
            .warning("Add a CHANGELOG entry."),
        ]
        let summary = Summary(
            report: Report(
                repository: "o/r",
                pullRequest: 7,
                headCommit: Self.head,
                findings: findings,
                generator: "Steward 1.0.0"
            ),
            serverURL: Self.server,
            origin: Self.run
        )
        #expect(summary.text == expected)
    }

    @Test("each kind gets a table in order, markdown follows as it is, and the headline counts every kind")
    func everyKind() {
        let findings: [Finding] = [
            .markdown("## Coverage\n\n- 98%"),
            .message("Thanks!"),
            .warning("First"),
            .message("Second message", at: Location(path: "README.md")),
            .warning("Second"),
            .markdown("Plain note"),
        ]
        #expect(Self.summary(findings) == """
            **2 warnings, 2 messages, 2 notes** on 4c95447

            | | Warnings |
            |---|---|
            | :warning: | First |
            | :warning: | Second |

            | | Messages |
            |---|---|
            | :book: | Thanks! |
            | :book: | Second message<br>[`README.md`](https://github.com/o/r/blob/\(Self.head)/README.md) |

            ## Coverage

            - 98%

            Plain note

            <sub>Steward · [workflow run](https://github.com/o/r/actions/runs/123) · 4c95447</sub>

            """)
    }

    @Test("one of each kind is counted in the singular")
    func singular() {
        let summary = Self.summary([.failure("f"), .warning("w"), .message("m"), .markdown("d")])
        #expect(summary.hasPrefix("**1 failure, 1 warning, 1 message, 1 note** on 4c95447\n\n"))
    }

    @Test("a report without findings says so above the footer")
    func noFindings() {
        #expect(Self.summary([]) == """
            **No findings** on 4c95447

            <sub>Steward · [workflow run](https://github.com/o/r/actions/runs/123) · 4c95447</sub>

            """)
    }

    @Test("a dry run's footer says so, and says when the pull request is a placeholder", arguments: [false, true])
    func dryRunFooter(isPlaceholder: Bool) {
        let note = isPlaceholder ? "dry run with a placeholder pull request" : "dry run"
        #expect(Self.summary([], origin: .dryRun(isPlaceholder: isPlaceholder)).hasSuffix("""
            <sub>Steward · \(note) · 4c95447</sub>

            """))
        #expect(Self.summary([], origin: .workflowRun(nil)).hasSuffix("<sub>Steward · 4c95447</sub>\n"))
    }

    @Test("cells keep a text's line breaks as <br> and its pipes escaped, and link its location below it")
    func cells() {
        let summary = Self.summary([.failure("Two\nlines | one pipe", at: Location(path: "a|b.swift", line: 3))])
        #expect(summary.contains("""
            | :no_entry_sign: | Two<br>lines \\| one pipe<br>[`a\\|b.swift:3`](https://github.com/o/r/blob/\(Self.head)/a%7Cb.swift#L3) |
            """))
        // A backslash that ends the text is a literal one, not a hard break.
        let backslash = Self.summary([.warning(#"C:\"#, at: Location(path: "a.swift"))])
        #expect(backslash.contains(#"| :warning: | C:\\<br>[`a.swift`]"#))
    }

    @Test("a path is shown verbatim and linked with each segment percent-encoded")
    func encodedPath() {
        let path = "dir with space/Ünï`cö#dé?.swift"
        let summary = Self.summary([.warning("w", at: Location(path: path, line: 1))])
        #expect(summary.contains("""
            [``dir with space/Ünï`cö#dé?.swift:1``](https://github.com/o/r/blob/\(Self.head)/dir%20with%20space/\
            %C3%9Cn%C3%AF%60c%C3%B6%23d%C3%A9%3F.swift#L1)
            """))
    }

    @Test("deleted files, an unknown repository, and an empty path show the location without a link")
    func unlinked() {
        let gone = Self.summary([.warning("w", at: Location(path: "Gone.swift"))], unlinkedPaths: ["Gone.swift"])
        #expect(gone.contains("| :warning: | w<br>`Gone.swift` |"))
        let unknown = Self.summary([.warning("w", at: Location(path: "a.swift", line: 2))], repository: "")
        #expect(unknown.contains("| :warning: | w<br>`a.swift:2` |"))
        let empty = Self.summary([.warning("w", at: Location(path: ""))])
        #expect(empty.contains("| :warning: | w<br>`` |"))
    }

    @Test("a line below 1 links to the file as a whole", arguments: [0, -3])
    func invalidLine(line: Int) {
        let summary = Self.summary([.message("m", at: Location(path: "a.swift", line: line))])
        #expect(summary.contains("| :book: | m<br>[`a.swift`](https://github.com/o/r/blob/\(Self.head)/a.swift) |"))
    }

    @Test("a markdown finding with a location gets its link below it, and an empty text only the link")
    func locatedNotes() {
        let note = Finding.markdown("## Note", at: Location(path: "a.swift", line: 4))
        let summary = Self.summary([note, .warning("", at: Location(path: "b.swift"))])
        #expect(summary.contains("## Note\n\n[`a.swift:4`](https://github.com/o/r/blob/\(Self.head)/a.swift#L4)\n\n"))
        #expect(summary.contains("| :warning: | [`b.swift`](https://github.com/o/r/blob/\(Self.head)/b.swift) |"))
    }

    @Test("links start from a GitHub Enterprise server's URL, with or without a trailing slash", arguments: [
        "https://ghe.example.com", "https://ghe.example.com/",
    ])
    func enterpriseServer(server: String) {
        let summary = Summary(
            report: Report(
                repository: "o/r",
                pullRequest: 1,
                headCommit: Self.head,
                findings: [.warning("w", at: Location(path: "a"))],
                generator: "Steward"
            ),
            serverURL: URL(string: server)!,
            origin: .workflowRun(nil)
        )
        #expect(summary.text.contains("(https://ghe.example.com/o/r/blob/\(Self.head)/a)"))
    }
}
