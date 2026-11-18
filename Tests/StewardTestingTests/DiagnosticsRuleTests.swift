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

    @Test("a report built at a commit the reader doesn't know is a failure naming it")
    func builtAtUnknownCommit() async throws {
        let workspace = try ReportWorkspace(reports: ["build.log": Self.buildLog])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.mixed, workspace: workspace.path)
        let rule = Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log", builtAt: "abc1234")])
        let findings = try await rule.evaluate(context)
        #expect(findings == [.failure("""
            The xcodebuild log `build.log`, built at `abc1234`, can't be read: the checkout has no such commit.
            """)])
    }

    /// The commit `builtLog` was built at, which put two lines above
    /// App.swift's.
    static let built = String(repeating: "b", count: 40)

    /// `SampleDiff.mixed`'s head to `built`, as `git diff -U0 -M` writes
    /// it.
    static let headToBuilt = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 2222222..7777777 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -0,0 +1,2 @@
        +// A header
        +// the base added

        """

    /// An xcodebuild log of `built`: on App.swift's added line, now line 4;
    /// on the base's header, which the head doesn't have; and on
    /// New.swift's added line, which the base left alone.
    static let builtLog = """
        /ci/checkout/Sources/App.swift:4:8: warning: imported module 'Logging' is never used
        /ci/checkout/Sources/App.swift:1:1: warning: the base's own
        /ci/checkout/Sources/New.swift:1:8: error: invalid redeclaration of 'New'
        """

    @Test("a report built at another commit maps to the head through the line map a test gives the reader")
    func builtAtMappedCommit() async throws {
        let workspace = try ReportWorkspace(reports: ["build.log": Self.builtLog])
        defer { workspace.remove() }
        var context = try Context.fixture(diff: SampleDiff.mixed, workspace: workspace.path)
        context.files = FakeRepositoryFiles([:], lineMaps: [Self.built: LineMap(diff: Self.headToBuilt)])
        let rule = Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log", builtAt: Self.built)])
        #expect(try await rule.evaluate(context) == [
            .warning("imported module 'Logging' is never used", at: Location(path: "Sources/App.swift", line: 2)),
            .failure("invalid redeclaration of 'New'", at: Location(path: "Sources/New.swift", line: 1)),
        ])
    }

    @Test("the rule asks the reader for the map to the head with the merge base's attributes, once per commit")
    func builtAtRequest() async throws {
        let workspace = try ReportWorkspace(reports: ["build.log": Self.builtLog, "other.log": Self.builtLog])
        defer { workspace.remove() }
        var context = try Context.fixture(diff: SampleDiff.mixed, workspace: workspace.path)
        let files = RecordingLineMaps(files: FakeRepositoryFiles([:], lineMaps: [Self.built: .identity]))
        context.files = files
        let rule = Rule.diagnosticsOnChangedLines(in: [
            .xcodebuild("build.log", builtAt: Self.built),
            .xcodebuild("other.log", builtAt: Self.built),
        ])
        _ = try await rule.evaluate(context)
        #expect(await files.requests.all == [[Self.built, context.git.head, context.git.mergeBase]])
    }

    @Test("a report built at the head itself needs no line map")
    func builtAtHead() async throws {
        let workspace = try ReportWorkspace(reports: ["build.log": Self.buildLog])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.mixed, workspace: workspace.path)
        let builtAtHead = Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log", builtAt: context.git.head)])
        let unnamed = Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log")])
        #expect(try await builtAtHead.evaluate(context) == unnamed.evaluate(context))
        #expect(try await builtAtHead.evaluate(context).count == 3)
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
