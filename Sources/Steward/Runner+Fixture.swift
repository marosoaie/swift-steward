import Foundation
import PullRequestHosting

/// What a run over a context built beforehand did: StewardTesting's
/// `Dangerfile.run(on:postingTo:)`.
package struct FixtureRun: Sendable {
    /// The status the process would exit with: 0, 1, or 2.
    package var exitStatus: Int32
    /// Nil when the run was cancelled before its rules finished.
    package var report: Report?
    /// The summary as the run showed it: the job summary in CI, standard
    /// output in a dry run; empty when it showed none.
    package var summary: String
    /// What the run logged on standard error.
    package var log: String

    /// Runs `rules` over `context` as a run in `context.run.mode` does once
    /// it has built its context, posting through `host` in place of
    /// GitHub's.
    ///
    /// Everything after the context is the real run's: the log, the
    /// rules, the report, the summary, the job summary, and the sticky
    /// comment. The run has no arguments and no environment of its own,
    /// so it writes no report file and its summary doesn't link to a
    /// workflow run.
    package init(running rules: [Rule], in context: Context, postingTo host: any PullRequestHost) async {
        // A file of the run's own, as Actions gives each step one, so a
        // comment cut short sends readers to it, as in CI.
        let jobSummary = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-job-summary-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: jobSummary) }
        let recording = RecordingConsole()
        let runner = Runner(
            arguments: [],
            program: "Dangerfile",
            environment: [
                // Never sent: `host` is the only host, and it takes none.
                "GITHUB_TOKEN": "steward-fixture-token",
                "GITHUB_STEP_SUMMARY": jobSummary.path,
            ],
            currentDirectory: context.run.workspace,
            console: recording.console,
            makeHost: { _, _, _, _, _ in host },
            // Fixed, so a test can compare logs: no one writes the
            // fixture's text to end the pause with.
            makeToken: { "steward-fixture" }
        )
        let runLog = Log(mode: context.run.mode, console: recording.console, makeToken: runner.makeToken)
        await runLog.group("Context") { Runner.describe(context, in: runLog) }
        let checked = await runner.run(rules, in: context, options: Options(), log: runLog)
        let (output, logged) = await recording.finishStreams()
        exitStatus = checked.status.rawValue
        report = checked.report
        summary = switch context.run.mode {
        case .actions: (try? Data(contentsOf: jobSummary)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        case .dryRun: output
        }
        log = logged
    }
}
