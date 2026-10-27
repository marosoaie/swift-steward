@testable import Dangerfile
import StewardTesting
import Testing

/// Every rule at once, as a run in GitHub Actions checks a pull request,
/// against a fake host that records what the run posts.
@Suite("Checks")
struct ChecksTests {
    @Test("an undescribed source change fails, and the summary is posted")
    func failing() async throws {
        let context = try Context.fixture(diff: SampleDiff.sources)
        let host = FakePullRequestHost(pullRequest: context.pullRequest)
        let outcome = await Checks.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 1)
        #expect(outcome.report?.findings.map(\.rule) == ["Description", "Changelog"])
        #expect(await host.comments.map(\.body) == [outcome.summary])
    }

    @Test("a described change with its changelog entry passes, and nothing is posted")
    func passing() async throws {
        let context = try Context.fixture(
            diff: SampleDiff.sourcesWithChangelog,
            pullRequest: .fixture(body: "Greets the user before printing.")
        )
        let host = FakePullRequestHost(pullRequest: context.pullRequest)
        let outcome = await Checks.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 0)
        #expect(outcome.report?.findings == [])
        #expect(await host.comments.isEmpty)
    }
}
