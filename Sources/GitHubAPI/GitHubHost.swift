import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import PullRequestHosting

/// GitHub as a `PullRequestHost`: its REST API, seen from one repository.
///
/// The summary comment is the comment whose first line is
/// `<!-- steward-summary -->`, which GitHub renders as nothing; the host
/// adds that line when it posts and strips it from what it returns. Any
/// other comment, a reply quoting the summary included, is left alone.
///
/// Works with GitHub Enterprise Server too: pass its API URL, which Actions
/// sets as `GITHUB_API_URL`. Requests use API version 2022-11-28.
public struct GitHubHost: PullRequestHost, CustomStringConvertible {
    /// How many pages of comments `summaryComments(onPullRequest:)` reads
    /// before giving up: 10,000 comments at 100 a page, far beyond any real
    /// pull request, so a server that always links a next page can't keep
    /// it reading forever.
    static let maximumCommentPages = 100

    let client: Client
    let owner: String
    let repository: String
    let apiURL: URL
    let summaryAuthor: String?
    let marker: SummaryMarker
    let commentsPerPage: Int

    /// Creates a host for one repository.
    ///
    /// - Parameters:
    ///   - owner: The account that owns the repository.
    ///   - repository: The repository's name, without the owner.
    ///   - token: A token for the API, such as a workflow's `GITHUB_TOKEN`;
    ///     nil or empty sends requests without one, which can read public
    ///     repositories only. It never appears in descriptions or errors.
    ///   - apiURL: The API's root, `https://api.github.com` for github.com.
    ///   - summaryAuthor: When set, only comments by this login count as
    ///     summary comments, for example `github-actions[bot]` in a
    ///     workflow. Nil accepts any author.
    public init(owner: String, repository: String, token: String?, apiURL: URL, summaryAuthor: String? = nil) {
        self.init(
            owner: owner,
            repository: repository,
            token: token,
            apiURL: apiURL,
            summaryAuthor: summaryAuthor,
            transport: URLSessionTransport()
        )
    }

    /// `middlewares` run after `RateLimitMiddleware`, so they see every
    /// response, and before the one that adds GitHub's headers and the
    /// token.
    init(
        owner: String,
        repository: String,
        token: String?,
        apiURL: URL,
        summaryAuthor: String? = nil,
        marker: SummaryMarker = .steward,
        commentsPerPage: Int = 100,
        transport: any ClientTransport,
        middlewares: [any ClientMiddleware] = []
    ) {
        self.owner = owner
        self.repository = repository
        self.apiURL = apiURL
        self.summaryAuthor = summaryAuthor
        self.marker = marker
        self.commentsPerPage = commentsPerPage
        client = Client(
            serverURL: apiURL,
            transport: transport,
            middlewares: [RateLimitMiddleware()] + middlewares + [
                GitHubHeadersMiddleware(token: token.flatMap { $0.isEmpty ? nil : $0 }),
            ]
        )
    }

    /// The repository and the API URL; never the token.
    public var description: String {
        "GitHubHost(\(owner)/\(repository) at \(apiURL.absoluteString))"
    }
}
