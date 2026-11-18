import GitDiffKit

/// A file the pull request creates or changes, as a rule from
/// `Rule.changedFiles` checks it: its path, its bytes at the head, and the
/// lines the pull request adds or rewrites there.
public struct ChangedFile: Sendable, Equatable {
    /// The file's path in the head commit, from the repository's root, as
    /// `GitChanges` lists it.
    public var path: String
    /// The file's bytes in the head commit, exactly as committed: no
    /// line-ending or encoding conversion, no filters.
    public var contents: [UInt8]
    /// The lines the pull request adds or rewrites, by their numbers in the
    /// head commit, as `GitChanges.changedLines(in:)` gives them: empty for
    /// a file it only renames, or whose mode alone it changes.
    public var changedLines: LineRangeSet

    /// Creates a changed file from its parts.
    public init(path: String, contents: [UInt8], changedLines: LineRangeSet) {
        self.path = path
        self.contents = contents
        self.changedLines = changedLines
    }
}
