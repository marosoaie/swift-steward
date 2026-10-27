import Foundation
@testable import Steward
import Testing

/// How a CI run's summary fits in the job summary and the comment, and
/// where each sends readers when it's cut short.
@Suite("A CI run's job summary and comment, cut to fit")
struct RunnerJobSummaryTests {
    static let runURL = RunnerPostingTests.runURL

    static func warnings(_ count: Int) -> [Rule] {
        RunnerPostingTests.warnings(count)
    }

    @Test("a summary too long for a comment is cut there, pointing at the job summary, which holds all of it")
    func longComment() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let outcome = try await RunnerTests.run(Self.warnings(1_000), on: fixture)
        let summary = try #require(outcome.jobSummary)
        #expect(summary.utf8.count > 100_000)
        #expect(!summary.contains("Everything is in"))
        let body = try #require(outcome.comments.first?.body)
        #expect(body.utf8.count <= 65_536)
        #expect(body.utf8.count > 65_536 - 300)
        #expect(body.contains("more findings. Everything is in the job summary of [the workflow run](\(Self.runURL))."))
    }

    @Test("a summary too long for what's left of the job summary is cut to fit, both pointing at the report or log",
          arguments: [false, true])
    func longJobSummary(writesReport: Bool) async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let earlier = String(repeating: "Earlier output.\n", count: 32_768)
        let outcome = try await RunnerTests.run(
            Self.warnings(5_000),
            writesReport ? ["--report", "report.json"] : [],
            on: fixture,
            jobSummary: earlier
        )
        let summary = try #require(outcome.jobSummary)
        #expect(summary.utf8.count <= 1 << 20)
        #expect(summary.utf8.count > (1 << 20) - 300)
        #expect(summary.hasPrefix(earlier + "\n\n**5000 warnings** on"))
        let elsewhere = writesReport ? "report artifact" : "log"
        let place = "Everything is in the \(elsewhere) of [the workflow run](\(Self.runURL))."
        #expect(summary.contains(place))
        let body = try #require(outcome.comments.first?.body)
        #expect(body.contains(place))
        #expect(outcome.report?.findings.count == (writesReport ? 5_000 : nil))
    }

    @Test("a job summary already at GitHub's limit is left alone, with a warning, and the comment points at the log")
    func fullJobSummary() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let earlier = String(repeating: "x", count: 1 << 20)
        let outcome = try await RunnerTests.run(Self.warnings(1_000), on: fixture, jobSummary: earlier)
        #expect(outcome.jobSummary == earlier)
        let path = fixture.repository.root.appendingPathComponent("summary.md").path
        #expect(outcome.log.contains("""
            ::warning title=Steward::The job summary at \(path) already holds 1048576 bytes, so the summary doesn't fit
            """))
        let body = try #require(outcome.comments.first?.body)
        #expect(body.contains("Everything is in the log of [the workflow run](\(Self.runURL))."))
    }

    @Test("a job summary that can't be written warns, and the comment points at the log")
    func unwritableJobSummary() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        var environment = try RunnerTests.environment(for: fixture)
        let path = fixture.repository.root.appendingPathComponent("missing/summary.md").path
        environment["GITHUB_STEP_SUMMARY"] = path
        let outcome = try await RunnerTests.run(Self.warnings(1_000), on: fixture, environment: environment)
        #expect(outcome.status == .clean)
        #expect(outcome.jobSummary == nil)
        #expect(outcome.log.contains("::warning title=Steward::Couldn't write the job summary to \(path): "))
        let body = try #require(outcome.comments.first?.body)
        #expect(body.contains("Everything is in the log of [the workflow run](\(Self.runURL))."))
    }
}
