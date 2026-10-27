@testable import DangerfileFixture
import StewardTesting
import Testing

@Suite("Dangerfile.run(on:postingTo:)")
struct DangerfileRunTests {
    @Test("a first run posts the summary its job summary shows, and exits with 0")
    func firstRun() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let host = FakePullRequestHost(pullRequest: context.pullRequest)
        let outcome = await FixtureChecks.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 0)
        #expect(outcome.report?.findings.map(\.rule) == [
            "Size", "New files", "Deleted files", "First edits", "First edits", "Commits",
        ])
        #expect(outcome.summary.hasPrefix("**1 warning, 4 messages, 1 note** on 4ead4ea"))
        #expect(await host.comments.map(\.body) == [outcome.summary])
        #expect(await host.requests == [
            .summaryComments(pullRequest: 1),
            .pullRequest(number: 1),
            .createSummaryComment(pullRequest: 1, body: outcome.summary),
        ])
        #expect(outcome.log.contains("""
            Posted the summary comment: https://github.com/octocat/hello-world/pull/1#issuecomment-1
            """))
    }

    @Test("the report names the pull request, its repository, and its head")
    func report() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let report = try #require(await FixtureChecks.run(on: context).report)
        #expect(report.repository == "octocat/hello-world")
        #expect(report.pullRequest == 1)
        #expect(report.headCommit == context.git.head)
        #expect(report.generator.hasPrefix("Steward "))
    }

    @Test("a later run updates the summary comment in place")
    func laterRun() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let host = FakePullRequestHost(pullRequest: context.pullRequest, comments: ["An older summary"])
        let outcome = await FixtureChecks.run(on: context, postingTo: host)
        #expect(await host.comments.map(\.body) == [outcome.summary])
        let id = SummaryComment.ID(rawValue: 1)
        #expect(await host.requests.last == .updateSummaryComment(id, body: outcome.summary))
    }

    @Test("after a race, the oldest summary comment is updated and the others deleted")
    func duplicates() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let host = FakePullRequestHost(pullRequest: context.pullRequest, comments: ["First", "Second", "Third"])
        let outcome = await FixtureChecks.run(on: context, postingTo: host)
        #expect(await host.comments.map(\.id.rawValue) == [1])
        #expect(await host.comments.map(\.body) == [outcome.summary])
        #expect(outcome.log.contains("and deleted 2 duplicates"))
    }

    @Test("a failure exits with 1, and a rule that throws is a failure while the others run")
    func failures() async throws {
        let context = try Context.fixture(
            diff: SampleDiff.mixed,
            pullRequest: .fixture(title: "Try \(FixtureChecks.throwMarker)", additions: 1001)
        )
        let outcome = await FixtureChecks.run(on: context)
        #expect(outcome.exitStatus == 1)
        let failures = outcome.report?.findings.filter { $0.kind == .failure }
        #expect(failures?.map(\.rule) == ["Large pull request", "Fixture marker"])
        #expect(failures?.last?.text.contains("the title asks this rule to throw") == true)
    }

    @Test("a clean pull request without a summary comment gets none")
    func cleanWithoutComment() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let host = FakePullRequestHost(pullRequest: context.pullRequest)
        let outcome = await Quiet.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 0)
        #expect(outcome.summary.hasPrefix("**No findings**"))
        #expect(await host.comments.isEmpty)
        #expect(await host.requests == [.summaryComments(pullRequest: 1)])
    }

    @Test("a clean pull request's summary comment is updated to say so")
    func allClear() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let host = FakePullRequestHost(pullRequest: context.pullRequest, comments: ["**1 failure** on 0000000"])
        let outcome = await Quiet.run(on: context, postingTo: host)
        #expect(await host.comments.map(\.body) == [outcome.summary])
        #expect(outcome.summary.hasPrefix("**No findings**"))
    }

    @Test("a run whose head has moved on writes nothing")
    func staleHead() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let host = FakePullRequestHost(pullRequest: context.pullRequest, comments: ["A newer run's summary"])
        await host.push(String(repeating: "f", count: 40))
        let outcome = await FixtureChecks.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 0)
        #expect(await host.comments.map(\.body) == ["A newer run's summary"])
        #expect(await host.requests == [.summaryComments(pullRequest: 1), .pullRequest(number: 1)])
        #expect(outcome.log.contains("so this run stops posting"))
    }

    @Test("a summary longer than the host takes is cut, and sends readers to the job summary")
    func cutSummary() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let host = FakePullRequestHost(pullRequest: context.pullRequest, maximumSummarySize: 2_000)
        let outcome = await Verbose.run(on: context, postingTo: host)
        let comment = try #require(await host.comments.first)
        #expect(outcome.summary.utf8.count > 2_000)
        #expect(comment.body.utf8.count <= 2_000)
        #expect(comment.body.contains("more findings. Everything is in"))
        #expect(comment.body.contains("job summary"))
        #expect(outcome.exitStatus == 0)
    }

    @Test("a fork's pull request is checked but gets no comment")
    func fork() async throws {
        var pullRequest = PullRequest.fixture()
        pullRequest.head.repository = "someone/hello-world"
        let context = try Context.fixture(diff: SampleDiff.mixed, pullRequest: pullRequest)
        let host = FakePullRequestHost(pullRequest: pullRequest)
        let outcome = await FixtureChecks.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 0)
        #expect(!outcome.summary.isEmpty)
        #expect(await host.requests.isEmpty)
        #expect(outcome.log.contains("a fork"))
    }

    @Test("a dry run prints the summary and sends the host nothing")
    func dryRun() async throws {
        var context = try Context.fixture(diff: SampleDiff.mixed)
        context.run.mode = .dryRun
        let host = FakePullRequestHost(pullRequest: context.pullRequest)
        let outcome = await FixtureChecks.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 0)
        #expect(outcome.summary.hasPrefix("**1 warning, 4 messages, 1 note**"))
        #expect(!outcome.log.contains("::group::"))
        #expect(await host.requests.isEmpty)
    }

    @Test("run(on:) posts to a fake host of its own, as run(on:postingTo:) does to a fresh one")
    func ownHost() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        let fresh = FakePullRequestHost(pullRequest: context.pullRequest)
        let withHost = await FixtureChecks.run(on: context, postingTo: fresh)
        #expect(await FixtureChecks.run(on: context) == withHost)
    }
}
