@testable import DangerfileFixture
import DiffDiagnostics
import Foundation
@testable import Steward
import Testing

/// The fixture Dangerfile's diagnostics rule, run as its own process on a
/// pull request whose base moved, held to `steward filter` on the same
/// linter's report of the head tree with the pull request's diff: what a
/// build of the head would have reported on the changed lines.
@Suite("The diagnostics rule end to end, against steward filter")
struct DiagnosticsRuleEndToEndTests {
    private static let rule = "Diagnostics on changed lines"

    /// The pull request, its base, and the merge commit Actions builds.
    ///
    /// From the fork point, the pull request edits lines 10 and 20 of
    /// `A.swift` and adds two lines after line 25, edits line 5 of
    /// `B.swift`, and adds `D.swift`. Meanwhile the base inserts four lines
    /// at the top of `A.swift` and rewrites its line 15, renames `B.swift`
    /// to `Sources/B2.swift` with two lines inserted at its top, and adds
    /// `E.swift`. Lines marked `lint-me` are what the linter reports.
    private struct Scenario {
        let repository: TestRepository
        let forkPoint: String
        let base: String
        let head: String
        let built: String

        init() throws {
            repository = try TestRepository()
            let a = (1...30).map { [3, 15].contains($0) ? "let a\($0) = \($0) // lint-me" : "let a\($0) = \($0)" }
            let b = (1...12).map { $0 == 8 ? "let b\($0) = \($0) // lint-me" : "let b\($0) = \($0)" }
            try repository.write(Self.text(a), to: "A.swift")
            try repository.write(Self.text(b), to: "B.swift")
            try repository.write(Self.text(["let c1 = 1", "let c2 = 2 // lint-me", "let c3 = 3"]), to: "C.swift")
            forkPoint = try repository.commit("Start", at: PullRequestFixture.time)

            try repository.git(["switch", "--quiet", "--create", "feature"])
            var headA = a
            headA[9] = "let a10 = 100 // lint-me"
            headA[19] = "let a20 = 200"
            headA.insert(contentsOf: ["let added1 = 1 // lint-me", "let added2 = 2"], at: 25)
            var headB = b
            headB[4] = "let b5 = 50 // lint-me"
            try repository.write(Self.text(headA), to: "A.swift")
            try repository.write(Self.text(headB), to: "B.swift")
            try repository.write(Self.text(["let d1 = 1", "let d2 = 2 // lint-me", "let d3 = 3"]), to: "D.swift")
            head = try repository.commit("Change files", at: PullRequestFixture.time + 100)

            try repository.git(["switch", "--quiet", "main"])
            var baseA = a
            baseA[14] = "let a15 = 1500 // lint-me"
            baseA.insert(contentsOf: ["// base 1 lint-me", "// base 2", "// base 3 lint-me", "// base 4"], at: 0)
            try repository.write(Self.text(baseA), to: "A.swift")
            try FileManager.default.createDirectory(
                at: repository.url.appendingPathComponent("Sources"),
                withIntermediateDirectories: true
            )
            try repository.git(["mv", "B.swift", "Sources/B2.swift"])
            try repository.write(Self.text(["// base b1 lint-me", "// base b2"] + b), to: "Sources/B2.swift")
            try repository.write(Self.text(["let e1 = 1 // lint-me", "let e2 = 2"]), to: "E.swift")
            base = try repository.commit("Move the base", at: PullRequestFixture.time + 150)

            try repository.git(["switch", "--quiet", "--create", "merge"])
            built = try repository.merge("feature", at: PullRequestFixture.time + 300)
        }

        /// What the linter reports on `commit`'s tree: a SwiftLint warning
        /// for every line marked `lint-me`, at the file's absolute path in
        /// the checkout, as SwiftLint prints paths.
        func lint(_ commit: String) throws -> String {
            let paths = try repository.git(["ls-tree", "-r", "--name-only", commit])
                .split(separator: "\n")
                .map(String.init)
            return try paths.flatMap { path in
                let contents = String(decoding: try repository.gitBytes(["show", "\(commit):\(path)"]), as: UTF8.self)
                return contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    .filter { $0.element.contains("lint-me") }
                    .map { "\(repository.path)/\(path):\($0.offset + 1):1: warning: Marked line (marker)\n" }
            }.joined()
        }

        /// Writes `contents` beside the repository and returns its path.
        func write(_ contents: String, to name: String) throws -> String {
            let url = repository.root.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url.path
        }

        private static func text(_ lines: [String]) -> String {
            lines.map { "\($0)\n" }.joined()
        }
    }

    /// The oracle: `steward filter` on the linter's report of the head
    /// tree, with the pull request's diff, as the rule's findings.
    private static func filterFindings(_ scenario: Scenario) throws -> [Finding] {
        let headLog = try scenario.write(try scenario.lint(scenario.head), to: "head.log")
        let diff = scenario.repository.root.appendingPathComponent("pull-request.diff")
        let arguments = ["diff", "--no-color", "--no-ext-diff", "-M", scenario.forkPoint, scenario.head]
        try scenario.repository.gitBytes(arguments).write(to: diff)
        let output = try Subprocess.output(of: [
            try BuiltExecutable.required("steward").path, "filter", headLog, "--diff", diff.path,
            "--tool", "swiftlint", "--format", "json", "--repo-root", scenario.repository.path,
        ])
        return try JSONDecoder().decode([MatchedDiagnostic].self, from: output).map { diagnostic in
            var finding = ChangedLineDiagnostics.finding(for: diagnostic, failingOn: .error)
            finding.rule = rule
            return finding
        }
    }

    private static let expectedLocations = [
        Location(path: "A.swift", line: 10),
        Location(path: "A.swift", line: 26),
        Location(path: "B.swift", line: 5),
        Location(path: "D.swift", line: 2),
    ]

    @Test("run as a workflow on the merge commit, the rule finds what filter finds on the head")
    func workflowRun() throws {
        let scenario = try Scenario()
        defer { scenario.repository.remove() }
        let builtLog = try scenario.write(try scenario.lint(scenario.built), to: "built.log")
        let expected = try Self.filterFindings(scenario)
        #expect(expected.map(\.location) == Self.expectedLocations)

        let directory = scenario.repository.root
        let summary = directory.appendingPathComponent("summary.md")
        try Data().write(to: summary)
        let outcome = try FixtureDangerfile.run(
            ["--report", "report.json"],
            environment: TestRepository.runEnvironment(adding: try scenario.repository.actionsEnvironment(
                base: scenario.base,
                head: scenario.head,
                built: scenario.built
            ).merging([
                "GITHUB_REPOSITORY": "o/r",
                "GITHUB_RUN_ID": "42",
                "GITHUB_STEP_SUMMARY": summary.path,
                FixtureChecks.diagnosticsVariable: "swiftlint\t\(builtLog)",
            ]) { $1 }),
            in: directory
        )
        let report = try JSONDecoder().decode(
            Report.self,
            from: Data(contentsOf: directory.appendingPathComponent("report.json"))
        )
        // The recorded event's counts may fail the fixture's size rule.
        #expect(outcome.status == (report.hasFailures ? 1 : 0))
        #expect(report.findings.filter { $0.rule == Self.rule } == expected)
        #expect(outcome.log.contains("""
            SwiftLint output \(builtLog): 12 diagnostics, 4 on changed lines, 5 dropped for lines the head commit \
            doesn't have
            """))
    }

    @Test("a dry run on the head, given the merge commit's report built at it, finds the same")
    func dryRun() throws {
        let scenario = try Scenario()
        defer { scenario.repository.remove() }
        let builtLog = try scenario.write(try scenario.lint(scenario.built), to: "built.log")
        let expected = try Self.filterFindings(scenario)
        try scenario.repository.git(["switch", "--quiet", "--detach", scenario.head])

        let reportURL = scenario.repository.root.appendingPathComponent("report.json")
        let outcome = try FixtureDangerfile.run(
            ["--base", scenario.base, "--report", reportURL.path],
            environment: TestRepository.runEnvironment(adding: [
                "GITHUB_REPOSITORY": "o/r",
                FixtureChecks.diagnosticsVariable: "swiftlint\t\(builtLog)\t\(scenario.built)",
            ]),
            in: scenario.repository.url
        )
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: reportURL))
        #expect(outcome.status == 0)
        #expect(report.findings.filter { $0.rule == Self.rule } == expected)
        #expect(outcome.log.contains("12 diagnostics, 4 on changed lines, 5 dropped"))
    }
}
