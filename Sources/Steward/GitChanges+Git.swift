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
        if try await git.isShallow() {
            try await Self.requireUncut(commits, base: base, head: head, git: git)
        }
        self.init(diff: diff, commits: commits, mergeBase: mergeBase, head: head)
    }

    /// Throws `ContextError.truncatedHistory` unless the shallow clone's
    /// cuts leave `commits`, read as `base..head`, as a full clone has them.
    ///
    /// Through a merge of the base into the branch, a shallow clone can
    /// reach a merge base and still get the range wrong. A cut on the
    /// head's side stops git log at a commit whose parents the clone
    /// lacks, so the range holds a commit with no parents (which in a full
    /// clone only an unrelated history merged in can bring). A cut on the
    /// base's side hides what lies below it from the base, so whatever the
    /// head reaches of that some other way joins the range, every commit
    /// with its parents. That can't happen when each cut the base reaches
    /// lies below every commit the range starts from: the parents of its
    /// commits that aren't in it. Conservative where the clone can't tell:
    /// a root the base reaches counts as a cut.
    private static func requireUncut(_ commits: [Commit], base: String, head: String, git: Git) async throws {
        if let cut = commits.first(where: \.parents.isEmpty) {
            throw ContextError.truncatedHistory(base: base, head: head, boundary: cut.sha)
        }
        let starts = Set(commits.flatMap(\.parents)).subtracting(commits.map(\.sha))
        // Imperative: each check awaits git, which the combinators can't.
        for start in starts.sorted() {
            if let cut = try await git.parentlessCommit(reachableFrom: base, notFrom: start) {
                throw ContextError.truncatedHistory(base: base, head: head, boundary: cut)
            }
        }
    }
}
