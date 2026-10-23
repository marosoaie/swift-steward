import Foundation
import Testing

/// End-to-end tests of the command line tool against a real-world diff:
/// swiftlang/swift PR #70000 (Apache 2.0), fetched from
/// https://github.com/swiftlang/swift/pull/70000.diff.
///
/// The expected totals were independently verified with git's own patch
/// parser: `git apply --numstat` reports the same 12 files and the same
/// per-file added-line counts.
@Suite("Real-world diff")
struct RealDiffTests {
    @Test("the command line tool parses the committed fixture end to end")
    func commandLineToolOnCommittedFixture() throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "swift-pr-70000", withExtension: "diff", subdirectory: "Fixtures"
        ))

        let json = try CommandLineTool.run(arguments: ["changes", fixtureURL.path])
        let entries = try JSONDecoder().decode([ChangesEntry].self, from: json)
        #expect(entries.count == 12)
        #expect(entries.reduce(0) { $0 + $1.lineCount } == 437)

        // `filter`: include/swift/AST/Types.h changed lines 4788–4790.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-fixture-smoke.log")
        try Data("""
        /ci/include/swift/AST/Types.h:4789:1: warning: on a changed line
        /ci/include/swift/AST/Types.h:10:1: warning: far from any change
        """.utf8).write(to: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }
        let filtered = String(decoding: try CommandLineTool.run(
            arguments: ["filter", logURL.path, "--diff", fixtureURL.path, "--format", "text"]
        ), as: UTF8.self)
        #expect(filtered.contains("on a changed line"))
        #expect(!filtered.contains("far from any change"))

        // --tool swiftlint must extract the rule and surface it as the
        // GitHub annotation title.
        let lintLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-fixture-lint.log")
        try Data("""
        /ci/include/swift/AST/Types.h:4789:1: warning: Line Length Violation: too long (line_length)
        """.utf8).write(to: lintLogURL)
        defer { try? FileManager.default.removeItem(at: lintLogURL) }
        let annotations = String(decoding: try CommandLineTool.run(
            arguments: [
                "filter", lintLogURL.path,
                "--diff", fixtureURL.path,
                "--tool", "swiftlint",
                "--format", "github",
            ]
        ), as: UTF8.self)
        #expect(annotations.contains("::warning file=include/swift/AST/Types.h,line=4789,col=1,title=line_length::"))
        #expect(annotations.contains("::Line Length Violation: too long"))
    }

    @Test("the command line tool filters a SonarQube report end to end")
    func commandLineToolWithSonarReport() throws {
        // --tool sonar reads an issues-search JSON report; the rule becomes
        // the annotation title and severities map onto ours.
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "swift-pr-70000", withExtension: "diff", subdirectory: "Fixtures"
        ))
        let sonarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-fixture-sonar.json")
        try Data("""
        {
          "issues": [
            {
              "rule": "swift:S1481",
              "severity": "CRITICAL",
              "component": "org:proj:include/swift/AST/Types.h",
              "line": 4789,
              "message": "on a changed line"
            },
            {
              "rule": "swift:S1481",
              "severity": "CRITICAL",
              "component": "org:proj:include/swift/AST/Types.h",
              "line": 10,
              "message": "far from any change"
            }
          ]
        }
        """.utf8).write(to: sonarURL)
        defer { try? FileManager.default.removeItem(at: sonarURL) }
        let sonarAnnotations = String(decoding: try CommandLineTool.run(
            arguments: [
                "filter", sonarURL.path,
                "--diff", fixtureURL.path,
                "--tool", "sonar",
                "--format", "github",
            ]
        ), as: UTF8.self)
        #expect(sonarAnnotations.contains(
            "::error file=include/swift/AST/Types.h,line=4789,title=swift%3AS1481::on a changed line"
        ))
        #expect(!sonarAnnotations.contains("far from any change"))
    }
}
