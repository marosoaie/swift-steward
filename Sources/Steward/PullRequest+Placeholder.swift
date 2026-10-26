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
        // once, though git's patch deletes and creates the path.
        let typeChanges = Set(changes.deletedFiles).intersection(changes.createdFiles).count
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
