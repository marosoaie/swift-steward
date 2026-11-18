import GitDiffKit

extension GitChanges {
    /// The lines the pull request adds or rewrites, by head path: what
    /// `ChangedLines(diff:)` reads from the same diff.
    ///
    /// Git writes a rewritten line as a deletion and an addition, so the
    /// added lines cover both; a deletion alone leaves no line at the head.
    /// Deleted files are left out, and so is a file whose changes add no
    /// line, such as a pure rename or a binary file. Each line goes
    /// straight into its file's merged ranges, which a diff's ascending
    /// lines extend in O(1).
    public var changedLines: ChangedLines {
        ChangedLines(files: diff.files.reduce(into: [String: LineRangeSet]()) { lines, file in
            guard let path = file.header.newPath?.string else { return }
            lines[path] = Self.addedLines(of: file, into: lines[path] ?? LineRangeSet())
        })
    }

    /// The lines the pull request adds or rewrites in the file at `path`
    /// in the head commit, as merged ranges; empty for a file it doesn't
    /// change that way.
    ///
    /// Reads only that file's lines, so a rule that asks about each
    /// changed file in turn doesn't parse the whole diff each time. Paths
    /// compare as `file(at:)` compares them, so a name's precomposed and
    /// decomposed spellings are one path.
    ///
    /// ```swift
    /// let header = 1...3
    /// let touched = context.git.modifiedFiles.filter {
    ///     context.git.changedLines(in: $0).overlaps(header)
    /// }
    /// ```
    public func changedLines(in path: String) -> LineRangeSet {
        diff.files.filter { $0.header.newPath?.string == path }.reduce(LineRangeSet()) { lines, file in
            Self.addedLines(of: file, into: lines)
        }
    }

    /// `lines` with `file`'s added lines inserted.
    static func addedLines(of file: DiffFile, into lines: LineRangeSet) -> LineRangeSet {
        file.lines.reduce(into: lines) { added, line in
            guard line.info.kind == .addition, let number = line.info.newNumber else { return }
            added.insert(number)
        }
    }
}
