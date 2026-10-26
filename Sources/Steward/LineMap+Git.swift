import GitDiffKit

extension LineMap {
    /// Reads the map from the commit `built` to the commit `head` from the
    /// local repository; the identity when they're the same commit.
    ///
    /// Diffs the whole tree: git detects renames only among the paths a
    /// pathspec selects, so limiting the diff to the pull request's paths
    /// would turn a file the base renamed into a deleted one.
    init(built: String, head: String, git: Git) async throws {
        guard built != head else {
            self = .identity
            return
        }
        self = try await git.diff(
            from: head,
            to: built,
            options: ["--unified=0"],
            into: Collector(),
            parsing: ParsingOptions()
        ).map
    }
}
