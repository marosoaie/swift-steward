@testable import Steward
import Testing

extension RunnerTests {
    @Test("rules that share a name get one warning annotation between the context and the rules")
    func sharedNames() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let outcome = try await Self.run(Self.rules + Self.rules.prefix(1), ["--report", "report.json"], on: fixture)
        #expect(outcome.status == .failures)
        #expect(outcome.log.contains("""
            ::endgroup::
            ::warning title=Steward::Some rules share a name, so the log and the report can't tell their findings \
            apart: “Deleted files” (2 rules). List each rule once, under its own name.
            ::group::Rules
            """))
        #expect(outcome.report?.findings.map(\.rule) == [
            "Deleted files", "Deleted files", "Edits", "Size", "Notes", "Deleted files", "Deleted files",
        ])
    }
}
