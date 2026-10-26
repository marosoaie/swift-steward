@testable import DangerfileFixture
import Foundation
@testable import Steward
import StewardVersion
import Testing

/// The fixture Dangerfile (`FixtureChecks`) as its own process, over
/// `PullRequestFixture`: what it prints, and every status it exits with.
@Suite("The fixture Dangerfile as a process")
struct FixtureProcessTests {
    @Test("--help prints the usage under the executable's name and exits 0")
    func help() throws {
        let outcome = try FixtureDangerfile.run(
            ["--help"],
            environment: TestRepository.runEnvironment(adding: [:]),
            in: FileManager.default.temporaryDirectory
        )
        #expect(outcome.status == 0)
        #expect(outcome.output == Options.usage(program: "DangerfileFixture"))
        #expect(outcome.log.isEmpty)
    }

    @Test("a workflow run exits 0 without a failure and 1 with one, writing the summary either way",
          arguments: [false, true])
    func workflowRun(asksToThrow: Bool) throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let environment = try Self.environment(for: fixture, title: asksToThrow ? FixtureChecks.throwMarker : "Fix")
        let outcome = try FixtureDangerfile.run(["--report", "report.json"], environment: environment,
                                                in: fixture.repository.root)
        let summary = try Self.jobSummary(of: fixture)
        let short = fixture.head.prefix(7)
        #expect(outcome.status == (asksToThrow ? 1 : 0))
        #expect(outcome.output.isEmpty)
        #expect(summary.hasPrefix("**\(asksToThrow ? "1 failure, " : "")1 warning, 5 messages, 1 note** on \(short)"))
        #expect(summary.contains("Rule “Fixture marker” failed") == asksToThrow)
        #expect(summary.hasSuffix("""
            <sub>Steward \(Release.version) · [workflow run](https://github.com/marosoaie/swift-steward/actions/runs/42) · \(short)</sub>

            """))
        let report = try JSONDecoder().decode(
            Report.self,
            from: Data(contentsOf: fixture.repository.root.appendingPathComponent("report.json"))
        )
        #expect(report.hasFailures == asksToThrow)
        #expect(outcome.log.hasPrefix("::group::Context\nPull request #21 in marosoaie/swift-steward: "))
        // No token: the process, whose host would go to GitHub, posts nothing.
        #expect(outcome.log.hasSuffix("""
            ::warning title=Steward::GITHUB_TOKEN isn't set, so Steward can't post the summary comment: give the \
            step `env: GITHUB_TOKEN: ${{ github.token }}`. The findings are in this run's log and job summary.

            """))
    }

    /// Ways a run can fail before it has a context.
    enum Breakage: String, CaseIterable {
        case unknownOption, unsupportedEvent, missingPayload, shallowClone, notACheckout
    }

    @Test("a run Steward can't do exits 2, says why, and writes no summary or report", arguments: Breakage.allCases)
    func broken(breakage: Breakage) throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        var arguments = ["--report", "report.json"]
        var environment = try Self.environment(for: fixture, title: "Fix")
        var workspace: TestRepository?
        switch breakage {
        case .unknownOption: arguments.append("--bsae")
        case .unsupportedEvent: environment["GITHUB_EVENT_NAME"] = "push"
        case .missingPayload:
            environment["GITHUB_EVENT_PATH"] = fixture.repository.root.appendingPathComponent("none").path
        case .shallowClone:
            let clone = try TestRepository(cloning: fixture.repository, options: ["--depth=1", "--branch=merge"])
            workspace = clone
            environment["GITHUB_WORKSPACE"] = clone.path
        case .notACheckout:
            // A dry run in the folder around the repository, which isn't in one.
            environment = TestRepository.runEnvironment(adding: [:])
        }
        defer { workspace?.remove() }
        let outcome = try FixtureDangerfile.run(arguments, environment: environment, in: fixture.repository.root)
        #expect(outcome.status == 2)
        #expect(outcome.output.isEmpty)
        let error = breakage == .notACheckout ? "error: A dry run checks the git checkout" : "::error title=Steward::"
        #expect(outcome.log.contains(error))
        #expect(try Self.jobSummary(of: fixture).isEmpty)
        let reportPath = fixture.repository.root.appendingPathComponent("report.json").path
        #expect(!FileManager.default.fileExists(atPath: reportPath))
    }

    /// A workflow run's environment on the fixture's pull request, with a
    /// payload titled `title` that adds 3 lines, and an empty job summary.
    static func environment(for fixture: PullRequestFixture, title: String) throws -> [String: String] {
        var environment = try RunnerTests.environment(for: fixture)
        // The process's host would send its requests to GitHub itself.
        environment["GITHUB_TOKEN"] = nil
        try EventPayload.recorded("pull-request-event.opened")
            .setting(base: fixture.base, head: fixture.head, fields: ["title": title, "additions": 3])
            .write(to: fixture.repository.eventURL)
        try Data().write(to: fixture.repository.root.appendingPathComponent("summary.md"))
        return TestRepository.runEnvironment(adding: environment)
    }

    static func jobSummary(of fixture: PullRequestFixture) throws -> String {
        String(decoding: try Data(contentsOf: fixture.repository.root.appendingPathComponent("summary.md")),
               as: UTF8.self)
    }
}
