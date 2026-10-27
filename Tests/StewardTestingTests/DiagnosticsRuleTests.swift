import StewardTesting
import Testing

/// The built-in diagnostics rule, tested as a Dangerfile's tests would:
/// with `StewardTesting` alone, on reports in the fixture's workspace.
@Suite("The diagnostics rule on a fixture context")
struct DiagnosticsRuleTests {
    /// An xcodebuild log for `SampleDiff.mixed`, which adds App.swift's
    /// line 2, New.swift's line 1, and After.swift's line 1: one
    /// diagnostic of each severity on an added line, one on a line the
    /// pull request leaves alone, and one in a file it doesn't touch.
    static let buildLog = """
        /ci/checkout/Sources/App.swift:2:8: warning: imported module 'Logging' is never used
        /ci/checkout/Sources/App.swift:4:8: warning: struct 'App' is never used
        /ci/checkout/Sources/New.swift:1:8: error: invalid redeclaration of 'New'
        /ci/checkout/Sources/After.swift:1:8: note: 'After' declared here
        /ci/checkout/Sources/Untouched.swift:3:1: warning: never reported
        """

    @Test("the diagnostics on added lines become findings at their lines, by severity")
    func addedLines() async throws {
        let workspace = try ReportWorkspace(reports: ["build.log": Self.buildLog])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.mixed, workspace: workspace.path)
        let findings = try await Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log")]).evaluate(context)
        #expect(findings == [
            .message("'After' declared here", at: Location(path: "Sources/After.swift", line: 1)),
            .warning("imported module 'Logging' is never used", at: Location(path: "Sources/App.swift", line: 2)),
            .failure("invalid redeclaration of 'New'", at: Location(path: "Sources/New.swift", line: 1)),
        ])
    }

    @Test("failing on warnings makes a warning a failure and leaves a note a message")
    func failingOnWarnings() async throws {
        let workspace = try ReportWorkspace(reports: ["build.log": Self.buildLog])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.mixed, workspace: workspace.path)
        let rule = Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log")], failingOn: .warning)
        let findings = try await rule.evaluate(context)
        #expect(findings.map(\.kind) == [.message, .failure, .failure])
    }

    @Test("a report missing from the workspace is one failure naming it")
    func missingReport() async throws {
        let workspace = try ReportWorkspace(reports: [:])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.mixed, workspace: workspace.path)
        let findings = try await Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log")]).evaluate(context)
        #expect(findings.map(\.kind) == [.failure])
        #expect(findings.first?.text.hasPrefix("Couldn't read the xcodebuild log `build.log`") == true)
    }

    @Test("a report built at another commit is a failure: a fixture has no checkout to map it through")
    func builtAtAnotherCommit() async throws {
        let workspace = try ReportWorkspace(reports: ["build.log": Self.buildLog])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.mixed, workspace: workspace.path)
        let rule = Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log", builtAt: "abc1234")])
        let findings = try await rule.evaluate(context)
        #expect(findings.map(\.kind) == [.failure])
        let text = findings.first?.text ?? ""
        #expect(text.hasPrefix("The xcodebuild log `build.log`, built at `abc1234`, can't be read"))
    }

    @Test("a whole run fails on the error, and its log says what the report held")
    func wholeRun() async throws {
        let workspace = try ReportWorkspace(reports: ["build.log": Self.buildLog])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.mixed, workspace: workspace.path)
        let host = FakePullRequestHost(pullRequest: context.pullRequest)
        let outcome = await BuildChecks.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 1)
        #expect(outcome.report?.findings.map(\.rule) == Array(repeating: "Diagnostics on changed lines", count: 3))
        #expect(outcome.log.contains("""
            xcodebuild log build.log: 5 diagnostics, 3 on changed lines, \
            0 dropped for lines the head commit doesn't have
            """))
        #expect(await host.comments.map(\.body) == [outcome.summary])
        #expect(outcome.summary.contains("invalid redeclaration of 'New'"))
    }
}
