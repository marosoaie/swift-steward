import PullRequestHosting

extension PullRequest {
    /// The pull request a `pulls/get` response describes. Event payloads
    /// (`GITHUB_EVENT_PATH`) decode with the same schema.
    init(_ pull: Components.Schemas.PullRequest) {
        self.init(
            number: pull.number,
            title: pull.title,
            body: pull.body ?? "",
            author: pull.user.login,
            state: pull.merged ? .merged : pull.state == .open ? .open : .closed,
            isDraft: pull.draft ?? false,
            base: Branch(name: pull.base.ref, commit: pull.base.sha, repository: pull.base.repo.fullName),
            head: Branch(name: pull.head.ref, commit: pull.head.sha, repository: pull.head.repo.fullName),
            labels: pull.labels.map(\.name),
            webURL: pull.htmlUrl,
            additions: pull.additions,
            deletions: pull.deletions,
            changedFiles: pull.changedFiles,
            commits: pull.commits
        )
    }
}
