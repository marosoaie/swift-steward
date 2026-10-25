import Foundation
import HTTPTypes

/// A response recorded from the GitHub API: the status, the headers the
/// client reads, and the body.
///
/// On disk (`Fixtures/<operation>.<scenario>.http`):
///
///     HTTP 200
///     content-type: application/json; charset=utf-8
///
///     [ … body … ]
///
/// Recordings keep only `content-type`, `etag`, `link`, `x-github-media-type`
/// and `x-github-api-version-selected`, so no request ids, OAuth scopes or
/// token metadata reach a fixture. The scenario names who recorded it:
/// `macos-…` with the maintainer's token, `actions-…` with a workflow's
/// `GITHUB_TOKEN` (as `github-actions[bot]`).
struct RecordedResponse {
    struct FormatError: Error, CustomStringConvertible {
        let fixture: String
        let problem: String

        var description: String {
            "\(fixture): \(problem)"
        }
    }

    let response: HTTPResponse
    let body: Data

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let blankLine = data.firstRange(of: Data("\n\n".utf8)) else {
            throw FormatError(fixture: url.lastPathComponent, problem: "no blank line after the headers")
        }
        let lines = String(decoding: data[..<blankLine.lowerBound], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP "),
              let code = Int(statusLine.dropFirst("HTTP ".count)) else {
            throw FormatError(fixture: url.lastPathComponent, problem: "the first line isn't `HTTP <status>`")
        }
        let fields = lines.dropFirst().compactMap { line -> HTTPField? in
            guard let colon = line.firstIndex(of: ":"),
                  let name = HTTPField.Name(String(line[..<colon])) else {
                return nil
            }
            return HTTPField(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        response = HTTPResponse(status: .init(code: code), headerFields: HTTPFields(fields))
        body = data[blankLine.upperBound...]
    }
}
