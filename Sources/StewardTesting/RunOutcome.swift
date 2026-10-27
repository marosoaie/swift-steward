/// What a Dangerfile's run over a fixture context did:
/// `Dangerfile.run(on:postingTo:)`'s result.
public struct RunOutcome: Sendable, Hashable {
    /// The status the process would exit with: 0 when no finding is a
    /// failure, 1 when one is, and 2 when Steward couldn't do its job.
    public var exitStatus: Int32
    /// The report, as `--report` writes it; nil when the run was
    /// cancelled before its rules finished.
    public var report: Report?
    /// The summary as the run showed it: what it appended to the job
    /// summary in `.actions` mode, or printed in a dry run. Empty when it
    /// showed none.
    public var summary: String
    /// What the run logged, with GitHub Actions' workflow commands in
    /// `.actions` mode.
    public var log: String

    /// Creates an outcome from its parts.
    public init(exitStatus: Int32, report: Report?, summary: String, log: String) {
        self.exitStatus = exitStatus
        self.report = report
        self.summary = summary
        self.log = log
    }
}
