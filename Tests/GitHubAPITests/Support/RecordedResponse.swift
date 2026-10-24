import Foundation
import HTTPTypes

/// A response recorded from the GitHub API: the status, the headers the
/// client reads, and the body.
///
/// On disk (`<operation>.<scenario>.http`):
///
///     HTTP 200
///     content-type: application/json; charset=utf-8
///
///     [ … body … ]
///
/// Only `keptHeaders` are recorded: everything else (request ids, OAuth
/// scopes, token expiry, rate-limit state) is dropped, so no credential
/// metadata reaches a fixture.
struct RecordedResponse {
    static let keptHeaders: [HTTPField.Name] = [
        .contentType,
        HTTPField.Name("link"),
        HTTPField.Name("etag"),
        HTTPField.Name("x-github-media-type"),
        HTTPField.Name("x-github-api-version-selected"),
    ].compactMap { $0 }

    let response: HTTPResponse
    let body: Data

    init(response: HTTPResponse, body: Data) {
        self.response = HTTPResponse(
            status: response.status,
            headerFields: HTTPFields(
                response.headerFields
                    .filter { Self.keptHeaders.contains($0.name) }
                    .sorted { $0.name.canonicalName < $1.name.canonicalName }
            )
        )
        self.body = body
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let split = data.firstRange(of: Data("\n\n".utf8)) else {
            throw FixtureFormatError(url: url, problem: "no blank line after the headers")
        }
        let lines = String(decoding: data[..<split.lowerBound], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP "),
              let code = Int(statusLine.dropFirst("HTTP ".count)) else {
            throw FixtureFormatError(url: url, problem: "first line is not `HTTP <status>`")
        }
        let fields = lines.dropFirst().compactMap { line -> HTTPField? in
            guard let colon = line.firstIndex(of: ":"),
                  let name = HTTPField.Name(String(line[..<colon])) else {
                return nil
            }
            return HTTPField(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        response = HTTPResponse(status: .init(code: code), headerFields: HTTPFields(fields))
        body = data[split.upperBound...]
    }

    var encoded: Data {
        let head = """
            HTTP \(response.status.code)
            \(response.headerFields.map { "\($0.name.canonicalName): \($0.value)" }.joined(separator: "\n"))
            """
        return Data((head.hasSuffix("\n") ? head : head + "\n").utf8) + Data("\n".utf8) + body
    }
}

struct FixtureFormatError: Error, CustomStringConvertible {
    let url: URL
    let problem: String

    var description: String {
        "\(url.lastPathComponent): \(problem)"
    }
}
