import GitDiffKit

extension GitChanges {
    /// The lines the pull request adds, by head path: what
    /// `ChangedLines(diff:)` reads from the same diff, for
    /// `DiagnosticMatcher`. Each line goes straight into its file's merged
    /// ranges, which a diff's ascending lines extend in O(1).
    var addedLines: ChangedLines {
        let lines = diff.files.reduce(into: [String: LineRangeSet]()) { lines, file in
            guard let path = file.header.newPath?.string else { return }
            lines[path] = file.lines.reduce(into: lines[path] ?? LineRangeSet()) { added, line in
                guard line.info.kind == .addition, let number = line.info.newNumber else { return }
                added.insert(number)
            }
        }
        return ChangedLines(files: lines)
    }
}
