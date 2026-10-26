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
    /// cut the history short on either side, which makes `base..head` miss
    /// commits or take in some of the base's.
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
        // Through a merge of the base into the branch, a shallow clone can
        // reach a merge base and still cut `base..head` short: at a commit
        // whose parents it lacks (git log stops there), or on the base's
        // side, where everything below the cut stops counting as the
        // base's and joins the range down to a root or another cut. Either
        // way the range holds a commit with no parents, which in a full
        // clone only an unrelated history merged in can bring.
        if let cut = commits.first(where: \.parents.isEmpty), try await git.isShallow() {
            throw ContextError.truncatedHistory(base: base, head: head, boundary: cut.sha)
        }
        self.init(diff: diff, commits: commits, mergeBase: mergeBase, head: head)
    }
}
