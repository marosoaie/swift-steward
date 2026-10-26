extension Log {
    /// A log that writes nothing, for a rule called outside a run, as a
    /// test calls `Rule.evaluate`.
    static let discarding = Log(mode: .dryRun, console: Console(writeOutput: { _ in }, writeError: { _ in }))
}
