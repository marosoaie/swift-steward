import GitDiffKit

extension GitChanges {
    /// The numbers of the lines the pull request adds or rewrites, by head
    /// path: what `ChangedLineNumbers(diff:)` reads from the same diff.
    ///
    /// Git writes a rewritten line as a deletion and an addition, so the
    /// added lines cover both; a deletion alone leaves no line at the head.
    /// Deleted files are left out, and so is a file whose changes add no
    /// line, such as a pure rename or a binary file. Each line goes
    /// straight into its file's merged ranges, which a diff's ascending
    /// lines extend in O(1).
    ///
    /// Computed on each read, from every line of the diff: read it once,
    /// before a loop over the files, not in it.
    public var changedLineNumbers: ChangedLineNumbers {
        ChangedLineNumbers(files: diff.files.reduce(into: [String: LineRangeSet]()) { lineNumbers, file in
            guard let path = file.header.newPath?.string else { return }
            lineNumbers[path] = Self.addedLineNumbers(of: file, into: lineNumbers[path] ?? LineRangeSet())
        })
    }

    /// The numbers of the lines the pull request adds or rewrites in the
    /// file at `path` in the head commit, as merged ranges; empty for a
    /// file it doesn't change that way.
    ///
    /// Reads only that file's lines, but decodes every file's path to
    /// find it, as `file(at:)` does: cheap for a few paths, quadratic in
    /// the diff's files when asked about each of them in turn, where
    /// reading `changedLineNumbers` once is linear. Paths compare as
    /// `file(at:)` compares them, so a name's precomposed and decomposed
    /// spellings are one path.
    ///
    /// ```swift
    /// let header = 1...3
    /// let touchesHeader = context.git.changedLineNumbers(in: "Package.swift").overlaps(header)
    ///
    /// let changed = context.git.changedLineNumbers
    /// let touched = context.git.modifiedFiles.filter { changed.files[$0]?.overlaps(header) ?? false }
    /// ```
    public func changedLineNumbers(in path: String) -> LineRangeSet {
        diff.files.filter { $0.header.newPath?.string == path }.reduce(LineRangeSet()) { lineNumbers, file in
            Self.addedLineNumbers(of: file, into: lineNumbers)
        }
    }

    /// `lineNumbers` with the numbers of `file`'s added lines inserted.
    static func addedLineNumbers(of file: DiffFile, into lineNumbers: LineRangeSet) -> LineRangeSet {
        file.lines.reduce(into: lineNumbers) { added, line in
            guard line.info.kind == .addition, let number = line.info.newNumber else { return }
            added.insert(number)
        }
    }
}
