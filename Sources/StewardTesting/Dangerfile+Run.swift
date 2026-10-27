extension Dangerfile {
    /// Runs the rules over `context` as `main()` does once it has built
    /// the context, posting through `host`, and returns what the run did.
    ///
    /// Everything after the context is a real run's: the rules in order, a
    /// rule that throws turned into a failure, the report, the summary,
    /// the log, and in `.actions` mode the job summary and the summary
    /// comment, cut to the host's size. The run has no options and no
    /// environment: it writes no report file, its summary links to no
    /// workflow run, and its token goes nowhere but `host`.
    ///
    /// In a dry run (`context.run.mode = .dryRun`) it prints the summary
    /// and sends `host` nothing.
    public static func run(on context: Context, postingTo host: any PullRequestHost) async -> RunOutcome {
        let run = await FixtureRun(running: rules, in: context, postingTo: host)
        return RunOutcome(exitStatus: run.exitStatus, report: run.report, summary: run.summary, log: run.log)
    }

    /// Runs the rules over `context` as `run(on:postingTo:)` does, posting
    /// to a `FakePullRequestHost` for the context's pull request that has
    /// no summary comment yet.
    public static func run(on context: Context) async -> RunOutcome {
        await run(on: context, postingTo: FakePullRequestHost(pullRequest: context.pullRequest))
    }
}
