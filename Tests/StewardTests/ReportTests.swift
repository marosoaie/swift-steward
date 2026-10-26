import Foundation
@testable import Steward
import Testing

@Suite("Reports")
struct ReportTests {
    static let report = Report(
        repository: "o/r",
        pullRequest: 7,
        headCommit: Context.stubHead,
        findings: [
            Finding(
                kind: .failure,
                text: "Write Legacy.m in Swift.",
                location: Location(path: "Sources/Legacy.m"),
                rule: "No new Objective-C"
            ),
            Finding(kind: .markdown, text: "## Notes/1", rule: "Notes"),
        ],
        generator: "Steward"
    )

    @Test("a report encodes to the same bytes every time: sorted snake-case keys, unescaped slashes")
    func encoding() throws {
        let expected = """
            {
              "findings" : [
                {
                  "kind" : "failure",
                  "location" : {
                    "path" : "Sources/Legacy.m"
                  },
                  "rule" : "No new Objective-C",
                  "text" : "Write Legacy.m in Swift."
                },
                {
                  "kind" : "markdown",
                  "rule" : "Notes",
                  "text" : "## Notes/1"
                }
              ],
              "generator" : "Steward",
              "head_commit" : "\(Context.stubHead)",
              "pull_request" : 7,
              "repository" : "o/r",
              "schema_version" : 1
            }
            """
        #expect(String(decoding: try Self.report.encoded(), as: UTF8.self) == expected)
        #expect(try Self.report.encoded() == Self.report.encoded())
    }

    @Test("a report survives a round trip through its JSON")
    func roundTrip() throws {
        #expect(try JSONDecoder().decode(Report.self, from: Self.report.encoded()) == Self.report)
    }

    @Test("a schema version this Steward doesn't know fails to decode", arguments: [0, 2])
    func unknownSchema(version: Int) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Self.report.encoded()) as? [String: Any])
        object["schema_version"] = version
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Report.self, from: data) }
    }

    @Test("a finding of an unknown kind fails the whole report")
    func unknownKind() throws {
        let json = String(decoding: try Self.report.encoded(), as: UTF8.self)
            .replacingOccurrences(of: #""kind" : "markdown""#, with: #""kind" : "suggestion""#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Report.self, from: Data(json.utf8)) }
    }

    @Test("a report has failures exactly when one of its findings is a failure")
    func failures() {
        var report = Self.report
        #expect(report.hasFailures)
        report.findings = [.warning("w"), .message("m"), .markdown("d")]
        #expect(!report.hasFailures)
        report.findings = []
        #expect(!report.hasFailures)
    }
}
