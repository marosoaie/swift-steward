import GitDiffKit

extension GitChanges {
    /// The lines the pull request adds, by head path: what
    /// `ChangedLines(diff:)` reads from the same diff, for
    /// `DiagnosticMatcher`.
    var addedLines: ChangedLines {
        let lines = diff.files.reduce(into: [String: [ClosedRange<Int>]]()) { lines, file in
            guard let path = file.header.newPath?.string else { return }
            lines[path, default: []] += file.lines.compactMap { line in
                line.info.kind == .addition ? line.info.newNumber.map { $0...$0 } : nil
            }
        }
        return ChangedLines(files: lines.mapValues { LineRangeSet($0) })
    }
}
