import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

    /// The longest comment GitHub takes, counted in UTF-8 bytes. Its 422
    /// says "maximum is 65536 characters", and no way of counting
    /// characters counts more of them than there are bytes, so a body of
    /// this many bytes is never too long, whatever GitHub counts.
    static let maximumCommentSize = 65_536

    /// A session that never answers from a cache. GitHub marks its responses
    /// `Cache-Control: private, max-age=60`, so `URLSession.shared` serves a
    /// repeated request from its cache for a minute: a comment posted or
    /// deleted a moment ago would be missing from the list, or still in it,
    /// and Steward would post a second summary.
    static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// The transport the public initializer uses, on `uncachedSession`.
    static func uncachedTransport() -> URLSessionTransport {
        URLSessionTransport(configuration: .init(session: uncachedSession))
    }

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
            transport: Self.uncachedTransport()
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

    /// GitHub's limit on a comment, less the marker line the host adds.
    public var maximumSummarySize: Int {
        Self.maximumCommentSize - marker.marking("").utf8.count
    }

    /// The repository and the API URL; never the token.
    public var description: String {
        "GitHubHost(\(owner)/\(repository) at \(apiURL.absoluteString))"
    }
}
