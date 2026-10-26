import GitDiffKit
import PullRequestHosting

extension PullRequest {
    /// The pull request a dry run without `--pull-request` stands in
    /// (docs/danger.md, section 2): the head commit's subject and body as
    /// the title and description, `author` as the author, number 0, open,
    /// no labels, and the sizes of the local changes, counted as GitHub
    /// counts them.
    static func placeholder(
        for changes: GitChanges,
        headCommit: Commit,
        author: String,
        base: Branch,
        head: Branch
    ) -> PullRequest {
        // Per file, so the diff's compact line storage is never copied out.
        func count(_ kind: LineInfo.Kind) -> Int {
            changes.diff.files.reduce(0) { total, file in total + file.lines.count { $0.info.kind == kind } }
        }
        // GitHub counts a type change (a file turned into a symlink, say)
        // once, though git's patch deletes and creates the path. By bytes,
        // as two paths can decode to one String.
        let deleted = Set(changes.diff.files.compactMap { $0.header.change == .deleted ? $0.header.oldPath : nil })
        let added = Set(changes.diff.files.compactMap { $0.header.change == .added ? $0.header.newPath : nil })
        let typeChanges = deleted.intersection(added).count
        return PullRequest(
            number: 0,
            title: headCommit.subject,
            body: headCommit.body,
            author: author,
            state: .open,
            isDraft: false,
            base: base,
            head: head,
            labels: [],
            webURL: "",
            additions: count(.addition),
            deletions: count(.deletion),
            changedFiles: changes.diff.files.count - typeChanges,
            commits: changes.commits.count
        )
    }
}
