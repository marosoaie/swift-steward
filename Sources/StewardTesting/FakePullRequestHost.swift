import GitHubAPI

/// A host in memory for one pull request, for tests: it keeps the pull
/// request's summary comments and records every request a run sends.
///
/// It answers as `GitHubHost` does: summary comments oldest first, a
/// comment longer than `maximumSummarySize` refused as `.rejected`, an
/// update of a comment that's gone as `.notFound`, and a deletion of one
/// as `false`. Another pull request's number gets `.notFound`, as on
/// GitHub. Comments it posts are by `github-actions[bot]`, with ids
/// counting up from 1.
///
/// ```swift
/// let host = FakePullRequestHost(pullRequest: context.pullRequest)
/// let outcome = await Checks.run(on: context, postingTo: host)
/// #expect(await host.comments.map(\.body) == [outcome.summary])
/// ```
public actor FakePullRequestHost: PullRequestHost {
    /// A request a run sent, with what it asked for.
    public enum Request: Sendable, Hashable {
        /// `pullRequest(number:)`, which a run sends before each write to
        /// check that the head hasn't moved.
        case pullRequest(number: Int)
        /// `summaryComments(onPullRequest:)`.
        case summaryComments(pullRequest: Int)
        /// `createSummaryComment(onPullRequest:body:)`.
        case createSummaryComment(pullRequest: Int, body: String)
        /// `updateSummaryComment(_:body:)`.
        case updateSummaryComment(SummaryComment.ID, body: String)
        /// `deleteSummaryComment(_:)`.
        case deleteSummaryComment(SummaryComment.ID)
    }

    /// What `GitHubHost` takes: 65,536 bytes less its marker line.
    @usableFromInline static let gitHubMaximumSummarySize = GitHubHost.stewardMaximumSummarySize

    /// The most UTF-8 bytes a summary comment may have.
    nonisolated public let maximumSummarySize: Int
    /// The pull request, with its head where the last `push(_:)` left it.
    public private(set) var pullRequest: PullRequest
    /// The summary comments on the pull request, oldest first.
    public private(set) var comments: [SummaryComment]
    /// Every request so far, in the order they came.
    public private(set) var requests: [Request] = []
    private var nextID: Int64

    /// Creates a host for `pullRequest`, with summary comments already
    /// posted when `comments` has any, as after earlier runs.
    ///
    /// - Parameters:
    ///   - pullRequest: The pull request the host serves; a run's context
    ///     should have the same one, as `Context.fixture(diff:)`'s and
    ///     the default here do when neither is given.
    ///   - comments: The text of the summary comments already on the pull
    ///     request, oldest first: one for a pull request a run has
    ///     commented on, more after two runs raced.
    ///   - maximumSummarySize: The most UTF-8 bytes a summary comment may
    ///     have; by default what `GitHubHost` takes, so a run cuts the
    ///     summary where it would on GitHub.
    public init(
        pullRequest: PullRequest = .fixture(),
        comments: [String] = [],
        maximumSummarySize: Int = FakePullRequestHost.gitHubMaximumSummarySize
    ) {
        self.pullRequest = pullRequest
        self.maximumSummarySize = maximumSummarySize
        self.comments = comments.enumerated().map { offset, body in
            Self.comment(id: Int64(offset) + 1, body: body, on: pullRequest)
        }
        nextID = Int64(comments.count) + 1
    }

    /// Moves the pull request's head to `commit`, as a push does: a run
    /// for the old head then stops before writing.
    public func push(_ commit: String) {
        pullRequest.head.commit = commit
    }

    /// The pull request, when `number` is its number.
    public func pullRequest(number: Int) async throws -> PullRequest {
        requests.append(.pullRequest(number: number))
        try requirePullRequest(number, operation: "pulls/get")
        return pullRequest
    }

    /// The summary comments, when `number` is the pull request's number.
    public func summaryComments(onPullRequest number: Int) async throws -> [SummaryComment] {
        requests.append(.summaryComments(pullRequest: number))
        try requirePullRequest(number, operation: "issues/list-comments")
        return comments
    }

    /// Posts a summary comment, unless `body` is too long or `number`
    /// isn't the pull request's.
    public func createSummaryComment(onPullRequest number: Int, body: String) async throws -> SummaryComment {
        let operation = "issues/create-comment"
        requests.append(.createSummaryComment(pullRequest: number, body: body))
        try requirePullRequest(number, operation: operation)
        try requireFitting(body, operation: operation)
        let comment = Self.comment(id: nextID, body: body, on: pullRequest)
        nextID += 1
        comments.append(comment)
        return comment
    }

    /// Replaces a summary comment's text, unless it's gone or `body` is
    /// too long.
    public func updateSummaryComment(_ id: SummaryComment.ID, body: String) async throws -> SummaryComment {
        let operation = "issues/update-comment"
        requests.append(.updateSummaryComment(id, body: body))
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            throw PullRequestHostError(kind: .notFound, operation: operation, message: "No comment \(id).")
        }
        try requireFitting(body, operation: operation)
        comments[index].body = body
        return comments[index]
    }

    /// Deletes a summary comment, and returns whether it was there.
    @discardableResult
    public func deleteSummaryComment(_ id: SummaryComment.ID) async throws -> Bool {
        requests.append(.deleteSummaryComment(id))
        let count = comments.count
        comments.removeAll { $0.id == id }
        return comments.count < count
    }

    private func requirePullRequest(_ number: Int, operation: String) throws {
        guard number == pullRequest.number else {
            throw PullRequestHostError(
                kind: .notFound,
                operation: operation,
                message: "No pull request #\(number); this host serves #\(pullRequest.number)."
            )
        }
    }

    private func requireFitting(_ body: String, operation: String) throws {
        guard body.utf8.count <= maximumSummarySize else {
            throw PullRequestHostError(
                kind: .rejected,
                operation: operation,
                message: "The comment has \(body.utf8.count) bytes, more than the \(maximumSummarySize) it may have."
            )
        }
    }

    private static func comment(id: Int64, body: String, on pullRequest: PullRequest) -> SummaryComment {
        SummaryComment(
            id: SummaryComment.ID(rawValue: id),
            body: body,
            author: "github-actions[bot]",
            webURL: "\(pullRequest.webURL)#issuecomment-\(id)"
        )
    }
}
