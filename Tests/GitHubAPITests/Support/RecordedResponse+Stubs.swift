import Foundation
import HTTPTypes
import Testing

extension RecordedResponse {
    /// `Fixtures/<name>.http`.
    init(fixture name: String) throws {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "http", subdirectory: "Fixtures"),
            "no fixture \(name).http"
        )
        try self.init(contentsOf: url)
    }

    /// A made-up response with a JSON body, for what the fixtures can't
    /// record safely: rate limits, server errors, more than one page.
    init(status: Int, headers: [String: String] = [:], json: Any) throws {
        let fields = [HTTPField(name: .contentType, value: "application/json; charset=utf-8")]
            + headers.map { HTTPField(name: HTTPField.Name($0.key)!, value: $0.value) }
        self.init(
            unfiltered: HTTPResponse(status: .init(code: status), headerFields: HTTPFields(fields)),
            body: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        )
    }

    /// The body, parsed without the generated types: the oracle the
    /// host's results are compared with.
    func jsonObject() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// A comment as GitHub sends it: the comment recorded in
    /// `issues-create-comment.macos-created`, with its id, text, and author
    /// replaced.
    static func comment(id: Int64, body: String, login: String = "marosoaie") throws -> [String: Any] {
        var comment = try RecordedResponse(fixture: "issues-create-comment.macos-created").jsonObject()
        var user = try #require(comment["user"] as? [String: Any])
        user["login"] = login
        comment["id"] = id
        comment["body"] = body
        comment["user"] = user
        comment["html_url"] = "https://github.com/marosoaie/swift-steward/pull/21#issuecomment-\(id)"
        return comment
    }

    /// One page of issues/list-comments, linking page `next` when there is
    /// one, as GitHub does.
    static func commentPage(_ comments: [[String: Any]], next: Int? = nil) throws -> RecordedResponse {
        let base = "https://api.github.com/repositories/1/issues/21/comments?per_page=100"
        let link = next.map { #"<\#(base)&page=\#($0)>; rel="next", <\#(base)&page=99>; rel="last""# }
        return try RecordedResponse(status: 200, headers: link.map { ["link": $0] } ?? [:], json: comments)
    }
}
