@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Changelog")
struct ChangelogTests {
    @Test("a change under Sources without a changelog entry gets a warning")
    func missing() async throws {
        let context = try Context.fixture(diff: SampleDiff.sources)
        let findings = try await Checks.changelog.evaluate(context)
        #expect(findings == [.warning("Add an entry to CHANGELOG.md for the changes under `Sources/`.")])
    }

    @Test("a changelog entry clears it")
    func entry() async throws {
        let context = try Context.fixture(diff: SampleDiff.sourcesWithChangelog)
        let findings = try await Checks.changelog.evaluate(context)
        #expect(findings.isEmpty)
    }

    @Test("a change outside Sources needs no entry")
    func outsideSources() async throws {
        let context = try Context.fixture(diff: SampleDiff.readme)
        let findings = try await Checks.changelog.evaluate(context)
        #expect(findings.isEmpty)
    }
}
