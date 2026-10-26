import GitDiffKit

extension GitChanges {
    /// Reads a pull request's changes from the local repository: the merge
    /// base of `base` and `head`, the diff from it to `head`, and the
    /// commits `base..head`.
    ///
    /// `base` and `head` are full commit SHAs that the repository has.
    /// Throws `ContextError.noMergeBase` when the history the repository
    /// has doesn't reach a common ancestor, and
    /// `ContextError.truncatedHistory` when it does but a shallow clone
    /// cut off some of the pull request's commits on the way.
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
        let commits = Commit.commits(fromLog: log)
        // A merge of the base into the branch can reach a merge base while
        // the branch's own older commits lie past the shallow boundary;
        // `git log` then silently stops at it.
        let boundary = try await git.shallowBoundary()
        if let cut = commits.first(where: { boundary.contains($0.sha) }) {
            throw ContextError.truncatedHistory(base: base, head: head, boundary: cut.sha)
        }
        self.init(diff: diff, commits: commits, mergeBase: mergeBase, head: head)
    }
}
