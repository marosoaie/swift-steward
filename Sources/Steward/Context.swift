import PullRequestHosting

/// Everything a rule may look at: the pull request, its changes, where
/// Steward runs, and the files of the commits it compares.
///
/// Steward gathers it once, before the first rule runs, and it doesn't
/// change after that. Every part is in head coordinates: line numbers are
/// the head commit's, as in the pull request's Files changed tab.
public struct Context: Sendable, Equatable {
    /// The pull request, from the event that started the run: a snapshot
    /// from when the event fired, read without an API call, so labels
    /// added since then are missing.
    public var pullRequest: PullRequest
    /// The pull request's changes, from the merge base to the head commit.
    public var git: GitChanges
    /// Where Steward runs, and which commit the build logs come from.
    public var run: Run
    /// Reads files from the merge base and the head commit, through git
    /// in a real run. Rules read through `contents(ofFileAt:at:limit:)`.
    public var files: any RepositoryFiles

    /// Creates a context from its parts.
    public init(pullRequest: PullRequest, git: GitChanges, run: Run, files: any RepositoryFiles) {
        self.pullRequest = pullRequest
        self.git = git
        self.run = run
        self.files = files
    }

    /// Whether two contexts hold the same pull request, changes, and run.
    ///
    /// The readers in `files` aren't compared: a reader has no equality,
    /// and a test's context equals a real run's when their data agree.
    public static func == (lhs: Context, rhs: Context) -> Bool {
        lhs.pullRequest == rhs.pullRequest && lhs.git == rhs.git && lhs.run == rhs.run
    }
}
