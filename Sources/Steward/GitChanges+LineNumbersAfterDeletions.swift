import GitDiffKit

extension GitChanges {
    /// Where the pull request deletes lines, by head path: for each run of
    /// deleted lines, the number of the head line that now stands where
    /// the run was, or one past the file's last line when the run was the
    /// file's end.
    ///
    /// Beside `changedLines`, it tells whether a declaration lost lines:
    /// one that spans `lines` changed when
    /// `changedLines.overlaps(lines) || linesAfterDeletions.overlaps(lines)`.
    /// That holds for a deletion inside the declaration and for any
    /// deletion directly above its first line: an attribute on a line of
    /// its own, but also a blank line or a whole function deleted there,
    /// which only the base's text tells apart. It doesn't hold for one
    /// directly below its last line: deleting a function doesn't mark the
    /// one before it. A rewritten line is a deletion too, and the line
    /// after it is its replacement's first.
    ///
    /// One past the file's last line is in none of its line ranges: a
    /// scope that runs to the file's end, such as its top-level code,
    /// counts that line as its own, or a file that only lost its last
    /// lines reads as unchanged. An emptied file gives line 1, which it
    /// doesn't have.
    ///
    /// Deleted files are left out, and so is a file whose changes delete no
    /// line, such as a pure rename, a binary file, or a new one. The
    /// numbers are those of the diff Steward reads, which has context: git
    /// can align repeated lines differently in one without, so
    /// `git diff --unified=0` may place, split or join a run differently
    /// among repeated lines, such as blank ones or lone braces.
    ///
    /// Computed on each read, from every line of the diff: read it once,
    /// before a loop over the files, not in it.
    public var linesAfterDeletions: ChangedLines {
        ChangedLines(files: diff.files.reduce(into: [String: LineRangeSet]()) { lines, file in
            guard file.header.change != .deleted, let path = file.header.newPath?.string else { return }
            lines[path] = Self.linesAfterDeletions(of: file, into: lines[path] ?? LineRangeSet())
        })
    }

    /// The head lines that directly follow a deletion in the file at
    /// `path` in the head commit, as `linesAfterDeletions` gives them; empty
    /// for a file the pull request deletes no line of.
    ///
    /// Reads only that file's lines, but decodes every file's path to find
    /// it, as `changedLines(in:)` does: read `linesAfterDeletions` once to
    /// ask about each file in turn.
    ///
    /// ```swift
    /// let declaration = 12...30
    /// let changed = context.git.changedLines(in: path).overlaps(declaration)
    ///     || context.git.linesAfterDeletions(in: path).overlaps(declaration)
    /// ```
    public func linesAfterDeletions(in path: String) -> LineRangeSet {
        diff.files.filter { $0.header.change != .deleted && $0.header.newPath?.string == path }
            .reduce(LineRangeSet()) { lines, file in Self.linesAfterDeletions(of: file, into: lines) }
    }

    /// `lines` with the head line after each of `file`'s runs of deleted
    /// lines inserted.
    static func linesAfterDeletions(of file: DiffFile, into lines: LineRangeSet) -> LineRangeSet {
        file.hunks.reduce(into: lines) { after, hunk in
            // Git gives an empty side's start as the line before it.
            var next = hunk.header.newCount == 0 ? hunk.header.newStart + 1 : hunk.header.newStart
            var isDeleting = false
            hunk.lines.forEach { line in
                if line.info.kind == .deletion {
                    isDeleting = true
                } else if let number = line.info.newNumber {
                    if isDeleting { after.insert(number) }
                    isDeleting = false
                    next = number + 1
                }
            }
            if isDeleting { after.insert(next) }
        }
    }
}
