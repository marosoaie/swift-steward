import PullRequestHosting

extension SummaryComment {
    /// The comment GitHub returned, with `body` in place of its text.
    init(_ comment: Components.Schemas.IssueComment, body: String) {
        self.init(
            id: ID(rawValue: comment.id),
            body: body,
            author: comment.user?.login,
            webURL: comment.htmlUrl
        )
    }
}
