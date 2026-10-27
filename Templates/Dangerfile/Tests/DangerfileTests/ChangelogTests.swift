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

    @Test("deleting the changelog isn't an entry")
    func deletedChangelog() async throws {
        let context = try Context.fixture(diff: SampleDiff.sourcesDeletingChangelog)
        let findings = try await Checks.changelog.evaluate(context)
        #expect(findings == [.warning("Add an entry to CHANGELOG.md for the changes under `Sources/`.")])
    }

    @Test("moving a file out of Sources is a change to them")
    func moveOutOfSources() async throws {
        let context = try Context.fixture(diff: SampleDiff.moveOutOfSources)
        let findings = try await Checks.changelog.evaluate(context)
        #expect(findings == [.warning("Add an entry to CHANGELOG.md for the changes under `Sources/`.")])
    }

    @Test("a change outside Sources needs no entry")
    func outsideSources() async throws {
        let context = try Context.fixture(diff: SampleDiff.readme)
        let findings = try await Checks.changelog.evaluate(context)
        #expect(findings.isEmpty)
    }
}
