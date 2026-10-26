import Foundation
@testable import Steward
import Testing

@Suite("Evaluating rules")
struct RuleEvaluationTests {
    struct Unreadable: LocalizedError {
        var errorDescription: String? { "Couldn't read build.log, ask @ada" }
    }

    struct Described: Error, CustomStringConvertible {
        var description: String { "the *linter* crashed" }
    }

    enum Broken: Error {
        case tool(status: Int)
    }

    @Test("rules run in order, and each finding is named after its rule, whatever the rule said")
    func orderAndNames() async throws {
        let rules = [
            Rule("First") { _ in [.message("1"), Finding(kind: .warning, text: "2", rule: "Impostor")] },
            Rule("Second") { _ in [] },
            Rule("Third") { _ in [.failure("3", at: Location(path: "a.swift", line: 1))] },
        ]
        let recording = RecordingConsole()
        let findings = try await rules.findings(in: .stub(), log: Log(mode: .dryRun, console: recording.console))
        #expect(findings.map(\.text) == ["1", "2", "3"])
        #expect(findings.map(\.rule) == ["First", "First", "Third"])
        #expect(findings[2].location == Location(path: "a.swift", line: 1))
        #expect(await recording.finish() == [
            .error("First: 2 findings\n"), .error("Second: 0 findings\n"), .error("Third: 1 finding, 1 failing\n"),
        ])
    }

    @Test("a rule that throws becomes a failure that quotes the error, escaped, and the next rule still runs")
    func thrownErrors() async throws {
        let rules = [
            Rule("Lint_*all*") { _ in throw Unreadable() },
            Rule("Described") { _ in throw Described() },
            Rule("Plain") { _ in throw Broken.tool(status: 3) },
            Rule("Own cancellation") { _ in throw CancellationError() },
            Rule("Last") { _ in [.message("still here")] },
        ]
        let log = Log(mode: .dryRun, console: RecordingConsole().console)
        let findings = try await rules.findings(in: .stub(), log: log)
        #expect(findings.map(\.kind) == [.failure, .failure, .failure, .failure, .message])
        #expect(findings.map(\.rule) == ["Lint_*all*", "Described", "Plain", "Own cancellation", "Last"])
        #expect(findings[0].text == "Rule “Lint\\_\\*all\\*” failed: Couldn't read build.log, ask @\u{200B}ada")
        #expect(findings[1].text == "Rule “Described” failed: the \\*linter\\* crashed")
        #expect(findings[2].text == "Rule “Plain” failed: StewardTests.RuleEvaluationTests.Broken.tool(status: 3)")
        #expect(findings[3].text == "Rule “Own cancellation” failed: Swift.CancellationError()")
        #expect(Report(repository: "o/r", pullRequest: 7, headCommit: "h", findings: findings, generator: "S")
            .hasFailures)
    }

    @Test("Foundation's errors read as Foundation describes them")
    func foundationErrors() throws {
        let error = try #require(throws: (any Error).self) {
            try Data(contentsOf: URL(fileURLWithPath: "/nonexistent/steward/build.log"))
        }
        let description = String(errorDescription: error)
        #expect(description.contains("build.log"))
        #expect(!description.contains("The operation couldn’t be completed"))
    }

    @Test("cancelling the run stops it before the next rule, whether the rule then returns or throws", arguments: [
        false, true,
    ])
    func cancellation(throwsAfterwards: Bool) async {
        let rules = [
            Rule("Cancels") { _ in
                unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
                if throwsAfterwards { throw Broken.tool(status: 1) }
                return [.message("partial")]
            },
            Rule("Never runs") { _ in [.message("ran")] },
        ]
        let recording = RecordingConsole()
        let log = Log(mode: .dryRun, console: recording.console)
        let outcome = await Task { try await rules.findings(in: .stub(), log: log) }.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(await recording.finish().isEmpty)
    }

    @Test("a run cancelled before its first rule runs none")
    func cancelledBeforehand() async {
        let rules = [Rule("Never runs") { _ in [.message("ran")] }]
        let recording = RecordingConsole()
        let log = Log(mode: .dryRun, console: recording.console)
        let outcome = await Task {
            unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
            return try await rules.findings(in: .stub(), log: log)
        }.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(await recording.finish().isEmpty)
    }
}
