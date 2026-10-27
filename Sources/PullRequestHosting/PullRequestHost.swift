/// A service that hosts pull requests, seen from one repository: it reads a
/// pull request and keeps Steward's summary comment on it.
///
/// How a host tells its summary comment from the others is its own business
/// (`GitHubHost` puts a hidden marker on the first line); callers see only
/// the text they posted. Every method throws `PullRequestHostError` when the
/// host fails or refuses, and `CancellationError` when the task is
/// cancelled.
public protocol PullRequestHost: Sendable {
    /// The most UTF-8 bytes a summary comment's text may have, whatever
    /// the host adds to it (such as its marker) already taken off. Longer
    /// text fails as `.rejected`.
    var maximumSummarySize: Int { get }

    /// The pull request with the given number.
    func pullRequest(number: Int) async throws -> PullRequest

    /// The summary comments on a pull request, oldest first.
    ///
    /// Usually none or one; more when two runs raced to create one. Reads
    /// every page of the pull request's comments.
    func summaryComments(onPullRequest number: Int) async throws -> [SummaryComment]

    /// Posts a new summary comment with the given text.
    func createSummaryComment(onPullRequest number: Int, body: String) async throws -> SummaryComment

    /// Replaces a summary comment's text.
    ///
    /// Throws a `.notFound` error when the comment is gone, for example
    /// deleted by hand since it was found.
    func updateSummaryComment(_ id: SummaryComment.ID, body: String) async throws -> SummaryComment

    /// Deletes a summary comment, and returns whether this call deleted it.
    ///
    /// Succeeds when the comment is already gone, for example deleted by
    /// another run since it was found, and returns false.
    @discardableResult
    func deleteSummaryComment(_ id: SummaryComment.ID) async throws -> Bool
}
