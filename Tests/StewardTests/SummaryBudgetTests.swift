import Foundation
@testable import Steward
import Testing

@Suite("The summary cut to a size")
struct SummaryBudgetTests {
    static let runURL = "https://github.com/o/r/actions/runs/123"

    static func summary(_ findings: [Finding], origin: Summary.Origin = SummaryTests.run) -> Summary {
        Summary(
            report: Report(
                repository: "o/r",
                pullRequest: 7,
                headCommit: SummaryTests.head,
                findings: findings,
                generator: "Steward"
            ),
            serverURL: SummaryTests.server,
            origin: origin
        )
    }

    /// Two of each kind, with and without locations.
    static let findings: [Finding] = [
        .markdown("## Coverage\n\n- 98%"),
        .warning("Add a CHANGELOG entry."),
        .failure("Write Legacy.m in Swift.", at: Location(path: "Sources/Legacy.m")),
        .message("Thanks!"),
        .failure("Unused variable 'count'.", at: Location(path: "Sources/Counter.swift", line: 12)),
        .message("New file", at: Location(path: "README.md")),
        .warning("Long | line\nbroken"),
        .markdown("Plain note", at: Location(path: "a.swift", line: 3)),
    ]

    @Test("a summary that fits is the whole summary, and one byte less cuts it")
    func fits() {
        let summary = Self.summary(Self.findings)
        let size = summary.text.utf8.count
        #expect(summary.text(fitting: size, elsewhere: .jobSummary) == summary.text)
        #expect(summary.text(fitting: .max, elsewhere: .log) == summary.text)
        let cut = summary.text(fitting: size - 1, elsewhere: .jobSummary)
        #expect(cut.utf8.count <= size - 1)
        // The last note is shorter than the cut line that replaces it.
        #expect(cut.contains("\n\n…and 2 more findings. Everything is in the job summary"))
    }

    // Every budget from what the headline and footer need to the whole
    // summary: the cut keeps the longest prefix of what the summary shows
    // that fits, in display order, and says how many findings it left out.
    @Test("at every size, the cut keeps the most findings that fit, in order, and counts the rest")
    func everyBudget() throws {
        let summary = Self.summary(Self.findings)
        let parts = summary.shownFindings.map { summary.part(for: $0) }
        let full = summary.text.utf8.count
        let rendering = { (kept: Int) -> String in
            summary.rendered(
                Array(parts.prefix(kept)),
                cutLine: kept == parts.count
                    ? nil
                    : summary.cutLine(dropped: parts.count - kept, isTextCut: false, elsewhere: .log)
            )
        }
        let smallest = rendering(0).utf8.count
        try (smallest..<full).forEach { budget in
            let cut = summary.text(fitting: budget, elsewhere: .log)
            #expect(cut.utf8.count <= budget, "budget \(budget)")
            #expect(cut.hasPrefix("**2 failures, 2 warnings, 2 messages, 2 notes** on 4c95447\n\n"))
            #expect(cut.hasSuffix("<sub>Steward · [workflow run](\(Self.runURL)) · 4c95447</sub>\n"))
            let kept = try #require(
                (0..<parts.count).first { rendering($0) == cut },
                "budget \(budget): not a prefix of the shown findings"
            )
            #expect(rendering(kept + 1).utf8.count > budget, "budget \(budget): \(kept + 1) findings fit")
        }
    }

    @Test("the cut line follows the last table or note shown, and the footer follows it")
    func layout() {
        let head = SummaryTests.head
        let expected = """
            **2 failures, 2 warnings, 2 messages, 2 notes** on 4c95447

            | | Failures |
            |---|---|
            | :no_entry_sign: | Write Legacy.m in Swift.<br>[`Sources/Legacy.m`](https://github.com/o/r/blob/\(head)/Sources/Legacy.m) |
            | :no_entry_sign: | Unused variable 'count'.<br>[`Sources/Counter.swift:12`](https://github.com/o/r/blob/\(head)/Sources/Counter.swift#L12) |

            | | Warnings |
            |---|---|
            | :warning: | Add a CHANGELOG entry. |
            | :warning: | Long \\| line<br>broken |

            | | Messages |
            |---|---|
            | :book: | Thanks! |

            …and 3 more findings. Everything is in the job summary of [the workflow run](\(Self.runURL)).

            <sub>Steward · [workflow run](\(Self.runURL)) · 4c95447</sub>

            """
        let summary = Self.summary(Self.findings)
        #expect(summary.text(fitting: expected.utf8.count, elsewhere: .jobSummary) == expected)
    }

    @Test("the cut line names where everything is, linking the workflow run when it can", arguments: [
        (Summary.Elsewhere.jobSummary, "the job summary of [the workflow run](\(runURL))"),
        (.reportArtifact, "the report artifact of [the workflow run](\(runURL))"),
        (.log, "the log of [the workflow run](\(runURL))"),
    ])
    func places(elsewhere: Summary.Elsewhere, place: String) {
        let linked = Self.summary(Self.findings)
        #expect(linked.cutLine(dropped: 3, isTextCut: false, elsewhere: elsewhere)
            == "…and 3 more findings. Everything is in \(place).")
        let name = place.components(separatedBy: " of ")[0].dropFirst("the ".count)
        let unlinked = [Summary.Origin.workflowRun(nil), .dryRun(isPlaceholder: false)].map {
            Self.summary(Self.findings, origin: $0).cutLine(dropped: 1, isTextCut: false, elsewhere: elsewhere)
        }
        let line = "…and 1 more finding. Everything is in the workflow run's \(name)."
        #expect(unlinked == [line, line])
    }

    @Test("a cut line for a text cut short says so, and counts the findings after it")
    func textCutLines() {
        let summary = Self.summary(Self.findings)
        #expect(summary.cutLine(dropped: 0, isTextCut: true, elsewhere: .log)
            == "…and the rest of the finding above. Everything is in the log of [the workflow run](\(Self.runURL)).")
        #expect(summary.cutLine(dropped: 2, isTextCut: true, elsewhere: .log).hasPrefix(
            "…and the rest of the finding above, and 2 more findings. Everything is in the log"
        ))
    }

    @Test("a first failure too long to fit shows as much of its text as fits, as code, with its link", arguments: [
        "plain words ", "a | pipe `tick` ``run`` <br> \\", "ünïcödé 🇷🇴 e\u{301} ",
    ])
    func firstRowCut(piece: String) throws {
        let text = String(repeating: piece, count: 5_000)
        let location = Location(path: "Sources/A.swift", line: 9)
        let summary = Self.summary([.failure(text, at: location), .warning("Next"), .markdown("Last")])
        let budget = 4_000
        let cut = summary.text(fitting: budget, elsewhere: .jobSummary)
        #expect(cut.utf8.count <= budget)
        // Within a few bytes of the budget: the search finds a long prefix.
        #expect(cut.utf8.count > budget - 16)
        let row = try #require(cut.split(separator: "\n").first { $0.hasPrefix("| :no_entry_sign: |") })
        #expect(row.contains(/…`+<br>\[`Sources\/A\.swift:9`\]/))
        #expect(row.hasSuffix("(https://github.com/o/r/blob/\(SummaryTests.head)/Sources/A.swift#L9) |"))
        #expect(cut.contains("\n\n…and the rest of the finding above, and 2 more findings. Everything is in"))
        #expect(!cut.contains("| :warning: |"))
        // What's shown is the text's beginning, whole characters only.
        let span = try #require(row.dropFirst("| :no_entry_sign: | ".count).components(separatedBy: "…").first)
        let shown = String(span.drop { $0 == "`" || $0 == " " })
            .replacingOccurrences(of: "\\|", with: "|")
        let expected = String(text.prefix(shown.count))
            .replacingOccurrences(of: "\n", with: " ")
        #expect(shown.count > 100)
        #expect(Self.unpadded(shown) == Self.unpadded(expected))
    }

    /// `text` without the spaces a code span pads its edges with.
    static func unpadded(_ text: String) -> Substring {
        text.drop { $0 == " " }
    }

    @Test("a first note too long to fit shows as much as fits in a code block no line of it can close")
    func firstNoteCut() throws {
        let text = String(repeating: "<details>\n\n````swift\nlet x = 1\n````\n", count: 3_000)
        let summary = Self.summary([.markdown(text), .markdown("Second")])
        let budget = 2_000
        let cut = summary.text(fitting: budget, elsewhere: .reportArtifact)
        #expect(cut.utf8.count <= budget)
        #expect(cut.utf8.count > budget - 16)
        let blocks = cut.components(separatedBy: "`````\n")
        #expect(blocks.count == 3, "one block, fenced by five backticks")
        #expect(text.hasPrefix(String(try #require(blocks[1].split(separator: "…").first))))
        #expect(blocks[2].hasPrefix("""

            …and the rest of the finding above, and 1 more finding. Everything is in the report artifact
            """))
    }

    @Test("a text too long for even its first character to fit shows no finding, and the cut line counts it")
    func nothingFits() {
        let location = Location(path: String(repeating: "deep/", count: 400) + "A.swift")
        let summary = Self.summary([.failure("x", at: location)])
        let cut = summary.text(fitting: 1_000, elsewhere: .log)
        #expect(cut.utf8.count <= 1_000)
        #expect(!cut.contains("| :no_entry_sign: |"))
        #expect(cut.contains("…and 1 more finding."))
    }

    @Test("a budget the headline and footer alone overrun gives them and the cut line, over budget")
    func tinyBudget() {
        let summary = Self.summary(Self.findings)
        let cut = summary.text(fitting: 10, elsewhere: .log)
        #expect(cut == summary.rendered([], cutLine: summary.cutLine(dropped: 8, isTextCut: false, elsewhere: .log)))
    }

    @Test("thousands of findings and a 10 MB text cut to GitHub's limit quickly", .timeLimit(.minutes(1)))
    func large() {
        let warnings = (1...5_000).map { (line: Int) in
            Finding.warning("Warning \(line)", at: Location(path: "A.swift", line: line))
        }
        let many = Self.summary(warnings + [.markdown(String(repeating: "x", count: 10_000_000))])
        let cut = many.text(fitting: 65_511, elsewhere: .jobSummary)
        #expect(cut.utf8.count <= 65_511)
        #expect(cut.utf8.count > 65_511 - 200)
        #expect(cut.hasPrefix("**5000 warnings, 1 note** on 4c95447"))

        let huge = Self.summary([.markdown(String(repeating: "y", count: 10_000_000))])
        let alone = huge.text(fitting: 65_511, elsewhere: .jobSummary)
        #expect(alone.utf8.count <= 65_511)
        #expect(alone.utf8.count > 65_511 - 16)
    }
}
