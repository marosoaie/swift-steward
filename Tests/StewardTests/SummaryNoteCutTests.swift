@testable import Steward
import Testing

// Regression (Copilot review): the cut could fall between a note that
// opens a block and the later note that closes it, and the cut line and
// the footer then rendered inside the block.
@Suite("The summary cut between notes, which never leaves a block open")
struct SummaryNoteCutTests {
    /// `summary` showing its first `kept` findings, and a cut line for the
    /// rest when there are any.
    static func rendering(_ summary: Summary, keeping kept: Int) -> String {
        let parts = summary.shownFindings.map { summary.part(for: $0) }
        let cutLine = kept == parts.count
            ? nil
            : summary.cutLine(dropped: parts.count - kept, isTextCut: false, elsewhere: .jobSummary)
        return summary.rendered(Array(parts.prefix(kept)), cutLine: cutLine)
    }

    /// Lines that make a note longer than the cut line that replaces it,
    /// so that dropping the note cuts the summary.
    static let filler = String(repeating: "More of it.\n", count: 20)

    @Test("a note that opens a block a later note closes is cut with it, not after it", arguments: [
        ("```swift\nlet x = 1", "```"),
        ("~~~\nlet x = 1", "~~~"),
        // Regression (Codex review): the mark joins the last tilde into one
        // Character, but GitHub still opens the fence.
        ("~~~\u{301}\nlet x = 1", "~~~"),
        ("<details><summary>Coverage</summary>\n\n- 98%", "</details>"),
        ("<!-- generated", "-->"),
        ("A <b>bold", "word</b>"),
    ])
    func blockAcrossNotes(opening: String, closing: String) {
        let summary = SummaryBudgetTests.summary([
            .warning("Add a CHANGELOG entry."),
            .markdown("Before"),
            .markdown(opening),
            .markdown(Self.filler + closing),
        ])
        // Room for the opening note and the cut line, not for the closing
        // note.
        let budget = Self.rendering(summary, keeping: 3).utf8.count
        #expect(summary.text.utf8.count > budget)
        let cut = summary.text(fitting: budget, elsewhere: .jobSummary)
        #expect(cut == Self.rendering(summary, keeping: 2))
        #expect(!cut.contains(opening))
    }

    @Test("notes that can't leave a block open are still cut one at a time")
    func selfContainedNotes() {
        let summary = SummaryBudgetTests.summary([
            .markdown("## Coverage\n\n| Module | % |\n|---|---|\n| A | 98 |"),
            .markdown("- one\n- two"),
            .markdown("> quoted"),
            .markdown("    indented code\n" + Self.filler),
        ])
        let budget = Self.rendering(summary, keeping: 3).utf8.count
        #expect(summary.text(fitting: budget, elsewhere: .jobSummary) == Self.rendering(summary, keeping: 3))
    }

    @Test("a first note that fits but might leave a block open isn't shown, nor cut short as code")
    func firstNoteOpens() {
        let opening = "```swift\n" + String(repeating: "let x = 1\n", count: 20)
        let summary = SummaryBudgetTests.summary([.markdown(opening), .markdown(Self.filler + "```")])
        let budget = Self.rendering(summary, keeping: 1).utf8.count
        let cut = summary.text(fitting: budget, elsewhere: .jobSummary)
        #expect(cut == Self.rendering(summary, keeping: 0))
        #expect(cut.contains("…and 2 more findings. Everything is in the job summary"))
    }

    @Test("a note is self-contained unless it has a code fence or HTML", arguments: [
        ("## Coverage\n\n- 98%", true),
        ("Two `code` spans, and ``one more``", true),
        ("$$\nx^2\n$$", true),
        ("```swift\nlet x = 1\n```", false),
        ("~~~\nx\n~~~", false),
        ("```\u{301}\nx", false),
        ("~~~\u{301}\nx", false),
        ("a <\u{338} b", false),
        ("a <b>bold</b> word", false),
        ("1 < 2", false),
    ])
    func selfContained(text: String, isSelfContained: Bool) {
        #expect(Summary.isSelfContained(text) == isSelfContained)
    }
}
