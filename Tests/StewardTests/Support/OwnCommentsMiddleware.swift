import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import Steward

/// Refuses, before it leaves the process, every request the live summary
/// comment test has no business sending: anything but reading its pull
/// request and that pull request's comments on api.github.com, commenting
/// on it, and editing or deleting a comment it created itself through this
/// middleware.
struct OwnCommentsMiddleware: ClientMiddleware {
    struct Refusal: Error, CustomStringConvertible {
        let method: HTTPRequest.Method
        let path: String

        var description: String {
            "the live test writes to its own comments on its pull request only: refused \(method.rawValue) \(path)"
        }
    }

    /// The comments created through the middleware, the only ones it lets
    /// requests edit or delete.
    actor Created {
        private(set) var ids: Set<Int64> = []

        func insert(_ id: Int64) {
            ids.insert(id)
        }
    }

    let repository: RepositoryName
    let pullRequest: Int
    let created = Created()

    @concurrent
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = String((request.path ?? "").prefix { $0 != "?" })
        let refusal = Refusal(method: request.method, path: path)
        let repositoryPath = "/repos/\(repository.owner)/\(repository.name)/"
        guard baseURL.absoluteString == "https://api.github.com", path.hasPrefix(repositoryPath),
              !path.contains("..") else { throw refusal }
        let rest = path.dropFirst(repositoryPath.count)
        let comments = "issues/\(pullRequest)/comments"
        switch request.method {
        case .get where rest == "pulls/\(pullRequest)" || rest == comments:
            return try await next(request, body, baseURL)
        case .post where rest == comments:
            let (response, responseBody) = try await next(request, body, baseURL)
            guard let responseBody else { return (response, nil) }
            let data = try await Data(collecting: responseBody, upTo: 1 << 22)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if response.status == .created, let id = (object?["id"] as? NSNumber)?.int64Value {
                await created.insert(id)
            }
            return (response, HTTPBody(data))
        case .patch, .delete:
            let id = rest.trimmingPrefix("issues/comments/")
            guard id.count < rest.count, let id = Int64(id), await created.ids.contains(id) else { throw refusal }
            return try await next(request, body, baseURL)
        default:
            throw refusal
        }
    }
}
