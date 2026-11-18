import StewardTesting
import Testing

/// `Rule(_:check:)` and `Log.write(_:)`, from outside Steward: a rule's
/// lines in the run's log.
@Suite("A rule's log")
struct RuleLogTests {
    @Test("a rule's lines show in the run's log, before the line counting its findings", arguments: [
        Run.Mode.actions, .dryRun,
    ])
    func lines(mode: Run.Mode) async throws {
        var context = try Context.fixture(diff: SampleDiff.mixed)
        context.run.mode = mode
        let outcome = await Logging.run(on: context)
        let forged = mode == .actions
            ? "::stop-commands::steward-fixture\n::error::forged\n::steward-fixture::\n"
            : #"\u{3A}:error::forged"# + "\n"
        #expect(outcome.log.contains("""
            Created: read Sources/New.swift
            \(forged)Created: 1 finding

            """), "\(outcome.log)")
        #expect(outcome.report?.findings.map(\.location?.path) == ["Sources/New.swift"])
    }

    @Test("in CI, the rule's lines are inside the run's group of rules")
    func grouped() async throws {
        let outcome = await Logging.run(on: try Context.fixture(diff: SampleDiff.mixed))
        let lines = outcome.log.split(separator: "\n", omittingEmptySubsequences: false)
        let start = try #require(lines.firstIndex(of: "::group::Rules"))
        let read = try #require(lines.firstIndex(of: "Created: read Sources/New.swift"))
        let end = try #require(lines[read...].firstIndex(of: "::endgroup::"))
        #expect(start < read && read < end)
    }

    @Test("calling the rule, as a test does, gives its check a log that writes nothing and returns its findings")
    func evaluate() async throws {
        let findings = try await Logging.created.evaluate(try Context.fixture(diff: SampleDiff.mixed))
        #expect(findings == [.message("A new file.", at: Location(path: "Sources/New.swift"))])
    }
}
