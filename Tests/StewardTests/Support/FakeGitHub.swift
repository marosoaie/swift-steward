import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import OpenAPIRuntime
import Testing

/// One pull request on a GitHub that lives in memory, served as the REST
/// API serves it to `GitHubHost`: `pulls/get`, and its comments, listed a
/// page at a time with a `link` header, created, updated, and deleted. It
/// records every request, and answers with a failure instead when one is
/// queued for the operation.
///
/// Any other request, or one without the token, fails the test.
actor FakeGitHub: ClientTransport {
    /// A comment on the pull request.
    struct Comment: Sendable, Equatable {
        var id: Int64
        var body: String
        var login: String
    }

    /// A request as it arrived.
    struct Request: Sendable, Equatable, CustomStringConvertible {
        var method: String
        /// With the query, as in `/repos/o/r/issues/21/comments?page=2&per_page=100`.
        var path: String
        /// The comment text it sends, for create and update.
        var text: String?

        var description: String {
            "\(method) \(path)"
        }
    }

    /// An answer that isn't what the API normally gives.
    enum Failure: Sendable {
        /// An error status with GitHub's error JSON.
        case status(Int, message: String, headers: [String: String] = [:])
        /// A success whose body isn't the operation's JSON.
        case malformed
        /// No response: the request never arrived.
        case network
        /// No response, but GitHub did what the request asked.
        case lostResponse
    }

    static let token = "fake-token-8d1e"
    static let owner = "marosoaie"
    static let repository = "swift-steward"

    let number: Int
    /// The account comments posted through the fake are by: the token's.
    let login: String
    private(set) var head: String
    private(set) var comments: [Comment]
    private(set) var requests: [Request] = []
    private var failures: [String: [Failure]] = [:]
    private var nextID: Int64 = 1_000

    init(number: Int = 21, head: String, comments: [Comment] = [], login: String = "github-actions[bot]") {
        self.number = number
        self.head = head
        self.comments = comments
        self.login = login
    }

    /// Answers the next requests of `operationID`, one each, with
    /// `failures`.
    func fail(_ operationID: String, with failures: Failure...) {
        self.failures[operationID, default: []] += failures
    }

    /// Moves the pull request's head, as a push does.
    func push(_ head: String) {
        self.head = head
    }

    /// Adds a comment, as someone else writing on the pull request does.
    @discardableResult
    func addComment(_ body: String, by login: String) -> Int64 {
        nextID += 1
        comments.append(Comment(id: nextID, body: body, login: login))
        return nextID
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let data = if let body { try await Data(collecting: body, upTo: 1 << 22) } else { Data() }
        let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["body"] as? String
        let path = request.path ?? ""
        requests.append(Request(method: request.method.rawValue, path: path, text: text))
        #expect(baseURL.absoluteString == "https://api.github.com")
        #expect(request.headerFields[.authorization] == "Bearer \(Self.token)")

        if let failure = failures[operationID]?.first {
            failures[operationID]?.removeFirst()
            switch failure {
            case let .status(status, message, headers):
                return try Self.json(status: status, Self.error(message, status: status), headers: headers)
            case .malformed:
                return try Self.json(status: 200, ["unexpected": true])
            case .network:
                throw URLError(.networkConnectionLost)
            case .lostResponse:
                _ = try answer(request.method, URLComponents(string: path), text: text)
                throw URLError(.networkConnectionLost)
            }
        }
        return try answer(request.method, URLComponents(string: path), text: text)
    }

    private func answer(
        _ method: HTTPRequest.Method,
        _ components: URLComponents?,
        text: String?
    ) throws -> (HTTPResponse, HTTPBody?) {
        let repositoryPath = "/repos/\(Self.owner)/\(Self.repository)/"
        let path = components?.path ?? ""
        guard path.hasPrefix(repositoryPath) else { return unexpected(method, path) }
        let route = String(path.dropFirst(repositoryPath.count))
        let commentPrefix = "issues/comments/"
        let query = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        switch (method, route) {
        case (.get, "pulls/\(number)"):
            return try Self.json(status: 200, try pullRequest())
        case (.get, "issues/\(number)/comments"):
            let perPage = Int(query["per_page"] ?? "") ?? 30
            let page = Int(query["page"] ?? "") ?? 1
            let start = min(comments.count, (page - 1) * perPage)
            let slice = comments[start..<min(comments.count, start + perPage)]
            let next = "https://api.github.com/repositories/1/issues/\(number)/comments?per_page=\(perPage)&page=\(page + 1)"
            let link = start + perPage < comments.count ? #"<\#(next)>; rel="next""# : nil
            return try Self.json(status: 200, try slice.map(Self.object), headers: link.map { ["link": $0] } ?? [:])
        case (.post, "issues/\(number)/comments"):
            let comment = Comment(id: nextID + 1, body: text ?? "", login: login)
            nextID += 1
            comments.append(comment)
            return try Self.json(status: 201, try Self.object(comment))
        case (.patch, _) where route.hasPrefix(commentPrefix), (.delete, _) where route.hasPrefix(commentPrefix):
            guard let id = Int64(route.dropFirst(commentPrefix.count)) else { return unexpected(method, path) }
            guard let index = comments.firstIndex(where: { $0.id == id }) else {
                return try Self.json(status: 404, Self.error("Not Found", status: 404))
            }
            if method == .delete {
                comments.remove(at: index)
                return (HTTPResponse(status: .noContent), nil)
            }
            comments[index].body = text ?? ""
            return try Self.json(status: 200, try Self.object(comments[index]))
        default:
            return unexpected(method, path)
        }
    }

    private func unexpected(_ method: HTTPRequest.Method, _ path: String) -> (HTTPResponse, HTTPBody?) {
        Issue.record("\(method) \(path) isn't a request Steward should send")
        return (HTTPResponse(status: .notFound), nil)
    }

    /// The pull request as `pulls/get` returns it: a recorded one, with
    /// this one's number and head.
    private func pullRequest() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(
            forResource: "swift-steward-26",
            withExtension: "json",
            subdirectory: "Fixtures/pulls"
        ))
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var headBranch = try #require(object["head"] as? [String: Any])
        headBranch["sha"] = head
        object["head"] = headBranch
        object["number"] = number
        return object
    }

    /// A comment as GitHub sends it: the recorded comment by
    /// github-actions[bot], with this one's id, text, and author.
    static func object(_ comment: Comment) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(
            forResource: "github-actions",
            withExtension: "json",
            subdirectory: "Fixtures/comments"
        ))
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var user = try #require(object["user"] as? [String: Any])
        user["login"] = comment.login
        object["user"] = user
        object["id"] = comment.id
        object["body"] = comment.body
        object["html_url"] = "https://github.com/\(owner)/\(repository)/pull/21#issuecomment-\(comment.id)"
        return object
    }

    /// GitHub's error JSON, which every error schema in its description
    /// requires the documentation link of.
    private static func error(_ message: String, status: Int) -> [String: Any] {
        [
            "message": message,
            "documentation_url": "https://docs.github.com/rest",
            "status": "\(status)",
        ]
    }

    private static func json(
        status: Int,
        _ object: Any,
        headers: [String: String] = [:]
    ) throws -> (HTTPResponse, HTTPBody?) {
        let fields = [HTTPField(name: .contentType, value: "application/json; charset=utf-8")]
            + (try headers.map { HTTPField(name: try #require(HTTPField.Name($0.key)), value: $0.value) })
        return (
            HTTPResponse(status: .init(code: status), headerFields: HTTPFields(fields)),
            HTTPBody(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        )
    }
}
