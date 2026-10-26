import Foundation

extension Summary {
    /// Where a summary that's cut short sends readers for all of it.
    enum Elsewhere: Sendable, Hashable {
        /// The workflow run's job summary, which holds all of it.
        case jobSummary
        /// The report the run wrote with `--report`, which the Action
        /// uploads as an artifact.
        case reportArtifact
        /// The workflow run's log, which always holds all of it.
        case log

        /// The sentence that says where a run's findings are when the
        /// summary comment doesn't hold them: the log, and this.
        var findingsSentence: String {
            switch self {
            case .jobSummary: "The findings are in this run's log and job summary."
            case .reportArtifact: "The findings are in this run's log and report."
            case .log: "The findings are in this run's log."
            }
        }
    }

    /// The Markdown in at most `budget` UTF-8 bytes (docs/danger.md,
    /// section 5), ending with a line break.
    ///
    /// When the whole summary doesn't fit, it's cut from the end: the
    /// notes first, then messages, warnings, and failures, last rows
    /// first, and a line before the footer says how much is missing and
    /// that `elsewhere` holds all of it. The headline still counts every
    /// finding. When not even the first finding fits, as much of its text
    /// as does is shown as code, so whatever the text opens, a code block
    /// or an HTML tag, can't swallow the rest of the comment. Only when the
    /// headline and footer alone don't fit is the result over budget.
    func text(fitting budget: Int, elsewhere: Elsewhere) -> String {
        let findings = shownFindings
        let parts = findings.map { part(for: $0) }
        // The headline and the footer, two line breaks between them and one
        // after.
        let base = headline.utf8.count + footer.utf8.count + 3
        // sizes[k]: the bytes of the first k parts' rendering, without a
        // cut line.
        let sizes = parts.indices.reduce(into: [base]) { sizes, index in
            sizes.append(sizes[index] + Self.cost(of: parts[index], after: index > 0 ? parts[index - 1] : nil))
        }
        guard sizes[parts.count] > budget else { return rendered(parts, cutLine: nil) }

        // Two line breaks before the cut line.
        let cutSize = { (dropped: Int, isTextCut: Bool) in
            2 + cutLine(dropped: dropped, isTextCut: isTextCut, elsewhere: elsewhere).utf8.count
        }
        let kept = parts.indices.last { sizes[$0] + cutSize(parts.count - $0, false) <= budget } ?? 0
        guard kept == 0, let first = findings.first,
              let cut = cutShort(first, toFit: budget - base - cutSize(parts.count - 1, true))
        else {
            return rendered(Array(parts.prefix(kept)), cutLine: cutLine(
                dropped: parts.count - kept,
                isTextCut: false,
                elsewhere: elsewhere
            ))
        }
        return rendered([cut], cutLine: cutLine(dropped: parts.count - 1, isTextCut: true, elsewhere: elsewhere))
    }

    /// The bytes `part` adds to a rendering whose last part is `previous`:
    /// a row adds a line to its table, or starts the table, header and
    /// all, after two line breaks; a note follows two line breaks.
    static func cost(of part: Part, after previous: Part?) -> Int {
        guard let table = part.table else { return 2 + part.text.utf8.count }
        guard previous?.table != table else { return 1 + part.text.utf8.count }
        return 2 + tables[table].header.utf8.count + 1 + part.text.utf8.count
    }

    /// The line that ends a summary cut short: what it leaves out, and
    /// where all of it is.
    func cutLine(dropped: Int, isTextCut: Bool, elsewhere: Elsewhere) -> String {
        let more = "\(dropped) more \(dropped == 1 ? "finding" : "findings")"
        let missing = switch (isTextCut, dropped) {
        case (true, 0): "the rest of the finding above"
        case (true, _): "the rest of the finding above, and \(more)"
        case (false, _): more
        }
        return "…and \(missing). Everything is in \(place(of: elsewhere))."
    }

    private func place(of elsewhere: Elsewhere) -> String {
        let name = switch elsewhere {
        case .jobSummary: "job summary"
        case .reportArtifact: "report artifact"
        case .log: "log"
        }
        guard case .workflowRun(let url?) = origin else { return "the workflow run's \(name)" }
        return "the \(name) of [the workflow run](\(url.absoluteString))"
    }

    /// The part for `finding` with as much of its text as fits in
    /// `available` bytes, the part's cost in a rendering of it alone, shown
    /// as code; nil when not even none of the text fits.
    private func cutShort(_ finding: Finding, toFit available: Int) -> Part? {
        // No more of the text can be shown than fits in `available` bytes,
        // so no more of it is looked at, however long it is.
        var bytes = 0
        let characters = Array(finding.text.prefix { character in
            bytes += character.utf8.count
            return bytes <= available
        })
        let fitting = { (count: Int) -> Part? in
            let part = part(for: finding, cutText: String(characters.prefix(count)))
            return Self.cost(of: part, after: nil) <= available ? part : nil
        }
        guard var best = fitting(0) else { return nil }
        var (low, high) = (0, characters.count)
        // Imperative: a binary search, which keeps the longest prefix found
        // to fit. Escaping makes the cost grow a little unevenly with the
        // prefix, so this finds a prefix that fits, near the longest.
        while low < high {
            let middle = low + (high - low + 1) / 2
            if let part = fitting(middle) {
                best = part
                low = middle
            } else {
                high = middle - 1
            }
        }
        return best
    }
}
