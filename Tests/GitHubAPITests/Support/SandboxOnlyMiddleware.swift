import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Refuses every request the sandbox test has no business sending, before
/// it leaves the process: anything outside api.github.com's sandbox
/// repository, a comment on any other pull request, and an update or delete
/// of anything but an issue comment.
struct SandboxOnlyMiddleware: ClientMiddleware {
    struct Refusal: Error, CustomStringConvertible {
        let method: HTTPRequest.Method
        let path: String

        var description: String {
            "the sandbox test writes to its sandbox pull request only: refused \(method.rawValue) \(path)"
        }
    }

    let owner: String
    let repository: String
    let pullRequest: Int

    func allows(method: HTTPRequest.Method, path: String, baseURL: URL) -> Bool {
        let repositoryPath = "/repos/\(owner)/\(repository)/"
        guard baseURL.absoluteString == "https://api.github.com", path.hasPrefix(repositoryPath),
              !path.contains("..") else {
            return false
        }
        let rest = path.dropFirst(repositoryPath.count)
        switch method {
        case .get:
            return true
        case .post:
            return rest == "issues/\(pullRequest)/comments"
        case .patch, .delete:
            let id = rest.trimmingPrefix("issues/comments/")
            return id.count < rest.count && !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber }
        default:
            return false
        }
    }

    @concurrent
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = String((request.path ?? "").prefix { $0 != "?" })
        guard allows(method: request.method, path: path, baseURL: baseURL) else {
            throw Refusal(method: request.method, path: path)
        }
        return try await next(request, body, baseURL)
    }
}
