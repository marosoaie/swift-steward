extension PullRequest {
    /// A pull request for a test, with a default for every field: #1,
    /// "Add a feature" by `octocat`, open, from `feature` into `main` of
    /// `octocat/hello-world`, without labels or a description, and with
    /// every size 0.
    ///
    /// The base and head commits are `ba5eba5e…` and `4ead4ead…`. Pass
    /// only the fields a rule reads; `Context.fixture(diff:)` counts the
    /// sizes from the diff when it builds the pull request itself.
    ///
    /// - Parameter webURL: The pull request's page; nil for GitHub's page
    ///   for `number` in the base repository.
    public static func fixture(
        number: Int = 1,
        title: String = "Add a feature",
        body: String = "",
        author: String = "octocat",
        state: State = .open,
        isDraft: Bool = false,
        base: Branch = Branch(
            name: "main",
            commit: FixtureDefaults.baseCommit,
            repository: FixtureDefaults.repository
        ),
        head: Branch = Branch(
            name: "feature",
            commit: FixtureDefaults.headCommit,
            repository: FixtureDefaults.repository
        ),
        labels: [String] = [],
        webURL: String? = nil,
        additions: Int = 0,
        deletions: Int = 0,
        changedFiles: Int = 0,
        commits: Int = 0
    ) -> PullRequest {
        PullRequest(
            number: number,
            title: title,
            body: body,
            author: author,
            state: state,
            isDraft: isDraft,
            base: base,
            head: head,
            labels: labels,
            webURL: webURL ?? "https://github.com/\(base.repository)/pull/\(number)",
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            commits: commits
        )
    }
}
