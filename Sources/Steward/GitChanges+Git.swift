import GitDiffKit

extension GitChanges {
    /// Reads a pull request's changes from the local repository: the merge
    /// base of `base` and `head`, the diff from it to `head`, and the
    /// commits `base..head`.
    ///
    /// `base` and `head` are full commit SHAs that the repository has.
    /// Throws `ContextError.noMergeBase` when the history the repository
    /// has doesn't reach a common ancestor.
    init(base: String, head: String, git: Git) async throws {
        guard let mergeBase = try await git.mergeBase(of: base, and: head) else {
            throw ContextError.noMergeBase(base: base, head: head, isShallow: try await git.isShallow())
        }
        // Three lines of context, as GitHub shows, whatever `diff.context` says.
        let diff = try await git.diff(
            from: mergeBase,
            to: head,
            options: ["--unified=3"],
            into: Diff.Collector(),
            parsing: .fullModel
        ).diff
        // Oldest first, and a commit never before its parents.
        let log = try await git.output([
            "log", "--no-color", "--no-show-signature", "--encoding=UTF-8", "--date-order", "--reverse",
            "-z", "--format=\(Commit.logFormat)", "\(base)..\(head)", "--",
        ])
        self.init(diff: diff, commits: Commit.commits(fromLog: log), mergeBase: mergeBase, head: head)
    }
}
