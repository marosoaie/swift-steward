import OpenAPIRuntime
import PullRequestHosting

extension GitHubHost {
    public func pullRequest(number: Int) async throws -> PullRequest {
        let operation = "pulls/get"
        return try await perform(operation) {
            let output = try await client.pullsGet(path: .init(owner: owner, repo: repository, pullNumber: number))
            switch output {
            case let .ok(response):
                return try PullRequest(response.body.json)
            // Only sent in answer to If-None-Match, which the host never sends.
            case .notModified:
                throw PullRequestHostError(operation: operation, status: 304, message: nil)
            case let .notFound(response):
                throw try PullRequestHostError(operation: operation, status: 404, message: response.body.json.message)
            case let .notAcceptable(response):
                throw try PullRequestHostError(operation: operation, status: 406, message: response.body.json.message)
            case let .unprocessableContent(response):
                throw try PullRequestHostError(operation: operation, status: 422, message: response.body.json.message)
            case let .internalServerError(response):
                throw try PullRequestHostError(operation: operation, status: 500, message: response.body.json.message)
            case let .serviceUnavailable(response):
                throw try PullRequestHostError(operation: operation, status: 503, message: response.body.json.message)
            case let .undocumented(status, payload):
                throw await PullRequestHostError(operation: operation, status: status, undocumented: payload)
            }
        }
    }

    public func summaryComments(onPullRequest number: Int) async throws -> [SummaryComment] {
        try await summaryComments(onPullRequest: number, fromPage: 1)
    }

    /// Reads one page, then the rest when its `link` header names a next
    /// one. An empty page ends the list whatever the header says.
    private func summaryComments(onPullRequest number: Int, fromPage page: Int) async throws -> [SummaryComment] {
        let operation = "issues/list-comments"
        let (comments, link) = try await perform(operation) {
            let output = try await client.issuesListComments(
                path: .init(owner: owner, repo: repository, issueNumber: number),
                query: .init(perPage: commentsPerPage, page: page)
            )
            switch output {
            case let .ok(response):
                return try (response.body.json, response.headers.link)
            case let .notFound(response):
                throw try PullRequestHostError(operation: operation, status: 404, message: response.body.json.message)
            case let .gone(response):
                throw try PullRequestHostError(operation: operation, status: 410, message: response.body.json.message)
            case let .undocumented(status, payload):
                throw await PullRequestHostError(operation: operation, status: status, undocumented: payload)
            }
        }
        let summaries = comments.compactMap(summary)
        guard !comments.isEmpty, let link, LinkHeader.namesNextPage(link) else {
            return summaries
        }
        guard page < Self.maximumCommentPages else {
            throw PullRequestHostError(
                kind: .malformedResponse,
                operation: operation,
                message: "page \(page) still links a next page; giving up after \(Self.maximumCommentPages)"
            )
        }
        return try await summaries + summaryComments(onPullRequest: number, fromPage: page + 1)
    }

    public func createSummaryComment(onPullRequest number: Int, body: String) async throws -> SummaryComment {
        let operation = "issues/create-comment"
        return try await perform(operation) {
            let output = try await client.issuesCreateComment(
                path: .init(owner: owner, repo: repository, issueNumber: number),
                body: .json(.init(body: marker.marking(body)))
            )
            switch output {
            case let .created(response):
                return try posted(response.body.json)
            case let .forbidden(response):
                throw try PullRequestHostError(operation: operation, status: 403, message: response.body.json.message)
            case let .gone(response):
                throw try PullRequestHostError(operation: operation, status: 410, message: response.body.json.message)
            case let .unprocessableContent(response):
                throw try PullRequestHostError(operation: operation, status: 422, message: response.body.json.message)
            case let .notFound(response):
                throw try PullRequestHostError(operation: operation, status: 404, message: response.body.json.message)
            case let .undocumented(status, payload):
                throw await PullRequestHostError(operation: operation, status: status, undocumented: payload)
            }
        }
    }

    public func updateSummaryComment(_ id: SummaryComment.ID, body: String) async throws -> SummaryComment {
        let operation = "issues/update-comment"
        return try await perform(operation) {
            let output = try await client.issuesUpdateComment(
                path: .init(owner: owner, repo: repository, commentId: id.rawValue),
                body: .json(.init(body: marker.marking(body)))
            )
            switch output {
            case let .ok(response):
                return try posted(response.body.json)
            case let .unprocessableContent(response):
                throw try PullRequestHostError(operation: operation, status: 422, message: response.body.json.message)
            // Declared by the update-comment-404 spec fix.
            case let .notFound(response):
                throw try PullRequestHostError(operation: operation, status: 404, message: response.body.json.message)
            case let .undocumented(status, payload):
                throw await PullRequestHostError(operation: operation, status: status, undocumented: payload)
            }
        }
    }

    public func deleteSummaryComment(_ id: SummaryComment.ID) async throws {
        let operation = "issues/delete-comment"
        try await perform(operation) {
            let output = try await client.issuesDeleteComment(
                path: .init(owner: owner, repo: repository, commentId: id.rawValue)
            )
            switch output {
            // A 404 means already gone (declared by the delete-comment-404
            // spec fix). It would also be GitHub's answer to a token that
            // can't see the repository, but then finding the comment would
            // have failed first.
            case .noContent, .notFound:
                return
            case let .undocumented(status, payload):
                throw await PullRequestHostError(operation: operation, status: status, undocumented: payload)
            }
        }
    }

    /// The summary comment `comment` is, or nil when it's another comment:
    /// one without the marker line, or by someone other than
    /// `summaryAuthor`.
    func summary(_ comment: Components.Schemas.IssueComment) -> SummaryComment? {
        guard summaryAuthor.map({ $0 == comment.user?.login }) ?? true,
              let body = comment.body.flatMap(marker.body(ofMarked:)) else {
            return nil
        }
        return SummaryComment(comment, body: body)
    }

    /// A comment this host just posted. Its marker comes back stripped; if
    /// GitHub ever returned the text without it, the text is kept whole.
    private func posted(_ comment: Components.Schemas.IssueComment) -> SummaryComment {
        SummaryComment(comment, body: comment.body.map { marker.body(ofMarked: $0) ?? $0 } ?? "")
    }

    /// Runs one request, turning whatever it throws into a
    /// `PullRequestHostError`, except cancellation, which stays a
    /// `CancellationError`.
    private func perform<Value>(_ operation: String, _ request: () async throws -> Value) async throws -> Value {
        do {
            return try await request()
        } catch let error as PullRequestHostError {
            throw error
        } catch let error as ClientError where error.underlyingError is CancellationError {
            throw CancellationError()
        } catch let error as ClientError {
            throw PullRequestHostError(operation: operation, clientError: error)
        } catch let error as CancellationError {
            throw error
        } catch {
            // Only the generated `json` accessors throw anything else, for a
            // body in a content type the response doesn't declare.
            throw PullRequestHostError(
                kind: .malformedResponse,
                operation: operation,
                message: String(describing: error)
            )
        }
    }
}
