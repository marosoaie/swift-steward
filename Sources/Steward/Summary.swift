import Foundation

/// A report rendered as the summary's GitHub-flavored Markdown
/// (docs/danger.md, section 5): a headline that counts the findings, a
/// table each of failures, warnings, and messages, the markdown findings
/// as they are, and a footer.
///
/// ```markdown
/// **2 failures, 1 warning** on 4c95447
///
/// | | Failures |
/// |---|---|
/// | :no_entry_sign: | Write Legacy.m in Swift.<br>[`Sources/Legacy.m`](https://github.com/o/r/blob/4c95447…/Sources/Legacy.m) |
/// …
/// <sub>Steward · [workflow run](https://github.com/o/r/actions/runs/123) · 4c95447</sub>
/// ```
///
/// Locations link to the head commit's blob on the server. A report
/// without findings renders as `**No findings** on 4c95447` and the footer.
struct Summary: Sendable {
    /// Where the run happened, as the footer says.
    enum Origin: Sendable, Hashable {
        /// In GitHub Actions; the footer links to the run when its URL is
        /// known.
        case workflowRun(URL?)
        /// Outside Actions, against the real pull request or a placeholder
        /// built from the head commit.
        case dryRun(isPlaceholder: Bool)
    }

    var report: Report
    /// The host's website, `https://github.com` or a GitHub Enterprise
    /// Server's, which links start from.
    var serverURL: URL
    var origin: Origin
    /// Paths the head commit doesn't have, such as deleted files: they're
    /// shown without a link, which would lead nowhere.
    var unlinkedPaths: Set<String> = []

    /// The Markdown, ending with a line break, whatever its size.
    var text: String {
        rendered(shownFindings.map { part(for: $0) }, cutLine: nil)
    }

    /// One finding's share of the summary: a row of one of the tables, or
    /// a note below them.
    struct Part: Sendable, Hashable {
        /// The index in `tables` of the table the row is in; nil for a
        /// note.
        var table: Int?
        var text: String
    }

    /// The findings in the order the summary shows them: the failures',
    /// warnings', and messages' tables, then the notes, each in rule
    /// order.
    var shownFindings: [Finding] {
        (Self.tables.map(\.kind) + [.markdown]).flatMap { kind in report.findings.filter { $0.kind == kind } }
    }

    /// The headline, the tables and notes of `parts`, `cutLine` when the
    /// summary is cut short, and the footer, ending with a line break.
    func rendered(_ parts: [Part], cutLine: String?) -> String {
        let tables = Self.tables.indices.compactMap { index -> String? in
            let rows = parts.filter { $0.table == index }.map(\.text)
            return rows.isEmpty ? nil : ([Self.tables[index].header] + rows).joined(separator: "\n")
        }
        let notes = parts.filter { $0.table == nil }.map(\.text)
        return ([headline] + tables + notes + [cutLine].compactMap(\.self) + [footer]).joined(separator: "\n\n") + "\n"
    }

    /// The share of the summary `finding` gets. With `cutText`, that's
    /// shown in place of the text, as code (see `text(fitting:elsewhere:)`).
    func part(for finding: Finding, cutText: String? = nil) -> Part {
        let location = finding.location.map(link)
        guard let table = Self.tables.firstIndex(where: { $0.kind == finding.kind }) else {
            let text = cutText.map { Markdown.codeBlock($0 + "…") } ?? finding.text
            return Part(table: nil, text: ([text] + [location].compactMap(\.self)).joined(separator: "\n\n"))
        }
        // Each part on its own, so a backslash that ends the text stays one.
        let text = cutText.map { Markdown.codeSpan($0 + "…") } ?? (finding.text.isEmpty ? nil : finding.text)
        let cell = [text, location].compactMap(\.self).map(Markdown.tableCell).joined(separator: "<br>")
        return Part(table: table, text: "| \(Self.tables[table].icon) | \(cell) |")
    }

    struct Table {
        var kind: Finding.Kind
        var title: String
        var icon: String

        var header: String {
            "| | \(title) |\n|---|---|"
        }
    }

    /// As danger-js lays them out, so a team coming from danger-swift
    /// recognizes the comment.
    static let tables = [
        Table(kind: .failure, title: "Failures", icon: ":no_entry_sign:"),
        Table(kind: .warning, title: "Warnings", icon: ":warning:"),
        Table(kind: .message, title: "Messages", icon: ":book:"),
    ]

    private struct Noun {
        var kind: Finding.Kind
        var singular: String
        var plural: String
    }

    private static let nouns = [
        Noun(kind: .failure, singular: "failure", plural: "failures"),
        Noun(kind: .warning, singular: "warning", plural: "warnings"),
        Noun(kind: .message, singular: "message", plural: "messages"),
        Noun(kind: .markdown, singular: "note", plural: "notes"),
    ]

    var headline: String {
        let counts = Self.nouns.compactMap { noun -> String? in
            let count = report.findings.count { $0.kind == noun.kind }
            return count == 0 ? nil : "\(count) \(count == 1 ? noun.singular : noun.plural)"
        }
        let what = counts.isEmpty ? "No findings" : counts.joined(separator: ", ")
        return "**\(what)** on \(shortCommit)"
    }

    var footer: String {
        let run: String? = switch origin {
        case .workflowRun(let url?): "[workflow run](\(url.absoluteString))"
        case .workflowRun(nil): nil
        case .dryRun(isPlaceholder: false): "dry run"
        case .dryRun(isPlaceholder: true): "dry run with a placeholder pull request"
        }
        let parts = [Markdown.escaped(report.generator), run, shortCommit].compactMap(\.self)
        return "<sub>\(parts.joined(separator: " · "))</sub>"
    }

    private var shortCommit: String {
        Markdown.escaped(String(report.headCommit.prefix(7)))
    }

    /// The location as a code span, linked to the head commit's blob when
    /// there is one to link to.
    private func link(to location: Location) -> String {
        let line = location.line.flatMap { $0 >= 1 ? $0 : nil }
        let code = Markdown.codeSpan(location.path + (line.map { ":\($0)" } ?? ""))
        let repository = report.repository.split(separator: "/", omittingEmptySubsequences: false)
        guard repository.count == 2, repository.allSatisfy({ !$0.isEmpty }),
              !location.path.isEmpty, !unlinkedPaths.contains(location.path)
        else { return code }
        let path = location.path.split(separator: "/", omittingEmptySubsequences: false)
            .map { Markdown.percentEncoded(String($0)) }
            .joined(separator: "/")
        let server = serverURL.absoluteString.hasSuffix("/")
            ? String(serverURL.absoluteString.dropLast())
            : serverURL.absoluteString
        let blob = [server] + repository.map { Markdown.percentEncoded(String($0)) }
            + ["blob", Markdown.percentEncoded(report.headCommit), path]
        return "[\(code)](\(blob.joined(separator: "/"))\(line.map { "#L\($0)" } ?? ""))"
    }
}
