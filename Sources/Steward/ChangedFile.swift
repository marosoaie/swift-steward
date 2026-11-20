import GitDiffKit

/// A file the pull request creates or changes, as a rule from
/// `Rule.changedFiles` checks it: its path, its bytes at the head, the
/// numbers of the lines the pull request adds or rewrites there, and of
/// the lines that follow what it deletes.
public struct ChangedFile: Sendable, Equatable {
    /// The file's path in the head commit, from the repository's root, as
    /// `GitChanges` lists it.
    public var path: String
    /// The file's bytes in the head commit, exactly as committed: no
    /// line-ending or encoding conversion, no filters.
    public var contents: [UInt8]
    /// The lines the pull request adds or rewrites, by their numbers in the
    /// head commit, as `GitChanges.changedLineNumbers(in:)` gives them:
    /// empty for a file it only renames, or whose mode alone it changes.
    public var changedLineNumbers: LineRangeSet
    /// The numbers of the head lines that directly follow each run of lines
    /// the pull request deletes, as
    /// `GitChanges.lineNumbersAfterDeletions(in:)` gives them: a
    /// declaration that spans `lineRange` changed when
    /// `changedLineNumbers.overlaps(lineRange)
    /// || lineNumbersAfterDeletions.overlaps(lineRange)`.
    public var lineNumbersAfterDeletions: LineRangeSet

    /// Creates a changed file from its parts.
    public init(
        path: String, contents: [UInt8], changedLineNumbers: LineRangeSet, lineNumbersAfterDeletions: LineRangeSet
    ) {
        self.path = path
        self.contents = contents
        self.changedLineNumbers = changedLineNumbers
        self.lineNumbersAfterDeletions = lineNumbersAfterDeletions
    }
}
