@testable import DangerfileFixture
import StewardTesting
import Testing

/// Rule tests as docs/rule-tests.md shows them: one call per rule, on the
/// fixture Dangerfile's rules.
@Suite("Rule tests")
struct RuleTests {
    @Test("a deleted file gets a warning at its path")
    func deletedFile() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let findings = try await FixtureChecks.deletedFiles.evaluate(context)
        #expect(findings == [.warning("Deleted", at: Location(path: "Docs/Old.md"))])
    }

    @Test("the size rule reports GitHub's counts for the diff")
    func size() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let findings = try await FixtureChecks.size.evaluate(context)
        #expect(findings == [.message("Changes 4 files (+3 −3) in 1 commits")])
    }

    @Test("the first added line of each edited Swift file gets a message, renames included")
    func firstEdits() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let findings = try await FixtureChecks.firstEdits.evaluate(context)
        #expect(findings == [
            .message("First added line", at: Location(path: "Sources/App.swift", line: 2)),
            .message("First added line", at: Location(path: "Sources/After.swift", line: 1)),
        ])
    }

    @Test("a pull request over the limit fails, whatever the diff")
    func largePullRequest() async throws {
        let context = try Context.fixture(
            diff: SampleDiff.mixed,
            pullRequest: .fixture(additions: FixtureChecks.addedLineLimit + 1)
        )
        let findings = try await FixtureChecks.largePullRequest.evaluate(context)
        #expect(findings == [.failure("Adds more than 1000 lines")])
    }

    @Test("the commits rule lists each commit's short SHA and subject")
    func commits() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed, commits: [
            .fixture(sha: "0123456789abcdef0123456789abcdef01234567", subject: "Add the parser"),
        ])
        let findings = try await FixtureChecks.commits.evaluate(context)
        #expect(findings == [.markdown("- `0123456` Add the parser")])
    }

    @Test("a rule that throws throws to its test")
    func throwingRule() async throws {
        let context = try Context.fixture(
            diff: SampleDiff.mixed,
            pullRequest: .fixture(title: "Try \(FixtureChecks.throwMarker)")
        )
        await #expect(throws: MarkerError.self) { try await FixtureChecks.fixtureMarker.evaluate(context) }
    }
}
