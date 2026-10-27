import BuildLogKit
import DiffDiagnostics
import Foundation
@testable import Steward
import Testing

/// The built-in rule's findings in the summary the sticky comment posts:
/// tool text escaped by `Markdown.escaped`, in table cells, and cut to the
/// byte budget.
@Suite("Diagnostics in the posted summary")
struct DiagnosticsSummaryTests {
    private static let blob = "https://github.com/o/r/blob/\(SummaryTests.head)/A.swift"

    /// The end of a row whose finding is on `line` of `A.swift`.
    private static func link(_ line: Int) -> String {
        "<br>[`A.swift:\(line)`](\(blob)#L\(line)) |"
    }

    private static func finding(
        _ message: String,
        _ severity: Diagnostic.Severity = .warning,
        rule: String? = nil,
        line: Int = 1
    ) -> Finding {
        ChangedLineDiagnostics.finding(
            for: MatchedDiagnostic(
                path: "A.swift", line: line, column: 1, severity: severity, message: message, rule: rule
            ),
            failingOn: .error
        )
    }

    @Test("backticks, issue numbers and at signs in tool text stay text, one table row each")
    func rows() {
        let summary = SummaryBudgetTests.summary([
            Self.finding("use ``` fences, or `x`", .error, rule: "r`s"),
            Self.finding("fixes #12, GH-3 and owner/repo#4", line: 2),
            // GitHub links neither the fullwidth at sign nor number sign.
            Self.finding("ping @octocat, not ＠octocat or ＃5", .note, line: 3),
        ])
        let rows = summary.text.split(separator: "\n").filter { $0.hasPrefix("| :") }.map(String.init)
        #expect(rows == [
            "| :no_entry_sign: | use \\`\\`\\` fences, or \\`x\\` (``r`s``)\(Self.link(1))",
            "| :warning: | fixes #\u{200B}12, GH-\u{200B}3 and owner/repo#\u{200B}4\(Self.link(2))",
            "| :book: | ping @\u{200B}octocat, not ＠octocat or ＃5\(Self.link(3))",
        ])
    }

    // The zero-width spaces and backslashes escaping adds are bytes the
    // budget has to count.
    @Test("at every size, a cut keeps whole rows of escaped tool text and stays within the budget")
    func everyBudget() {
        let summary = SummaryBudgetTests.summary((1...6).map { line in
            Self.finding(
                "#\(line) ``` @a ＠b GH-\(line) | \\",
                line.isMultiple(of: 2) ? .error : .warning,
                rule: "r`\(line)",
                line: line
            )
        })
        let parts = summary.shownFindings.map { summary.part(for: $0) }
        let rendering = { (kept: Int) -> String in
            summary.rendered(
                Array(parts.prefix(kept)),
                cutLine: kept == parts.count
                    ? nil
                    : summary.cutLine(dropped: parts.count - kept, isTextCut: false, elsewhere: .log)
            )
        }
        let full = summary.text.utf8.count
        #expect(summary.text(fitting: full, elsewhere: .log) == summary.text)
        (rendering(0).utf8.count..<full).forEach { budget in
            let cut = summary.text(fitting: budget, elsewhere: .log)
            #expect(cut.utf8.count <= budget, "budget \(budget)")
            // Short of the first row, the first finding may be cut short
            // instead, which `firstRowCut` checks.
            guard let kept = (0..<parts.count).first(where: { rendering($0) == cut }) else {
                #expect(rendering(1).utf8.count > budget, "budget \(budget): not a prefix of the shown findings")
                #expect(cut.contains("\n\n…and the rest of the finding above, and 5 more findings."))
                return
            }
            #expect(rendering(kept + 1).utf8.count > budget, "budget \(budget): \(kept + 1) findings fit")
        }
    }

    @Test("a first diagnostic too long to fit shows the start of its escaped text as code, within the budget")
    func firstRowCut() throws {
        let message = String(repeating: "fixes #12 ``` ＠octocat @octocat ", count: 3_000)
        let summary = SummaryBudgetTests.summary([Self.finding(message, .error), Self.finding("next", line: 2)])
        let budget = 4_000
        let cut = summary.text(fitting: budget, elsewhere: .jobSummary)
        #expect(cut.utf8.count <= budget)
        #expect(cut.utf8.count > budget - 16)
        let row = try #require(cut.split(separator: "\n").first { $0.hasPrefix("| :no_entry_sign: |") })
        // Every backtick of the escaped text follows a backslash, so two
        // fence the span, and GitHub links nothing inside it.
        let span = try #require(
            row.dropFirst("| :no_entry_sign: | ``".count).components(separatedBy: "…``<br>[`A.swift:1`]").first
        )
        #expect(span.count > 100)
        #expect(Markdown.escaped(message).hasPrefix(span))
        #expect(cut.contains("\n\n…and the rest of the finding above, and 1 more finding. Everything is in"))
    }
}
