import PullRequestHosting

/// Everything a rule may look at: the pull request, its changes, and where
/// Steward runs.
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

    /// Creates a context from its parts.
    public init(pullRequest: PullRequest, git: GitChanges, run: Run) {
        self.pullRequest = pullRequest
        self.git = git
        self.run = run
    }
}
