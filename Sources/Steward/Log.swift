import OutputEscaping

/// A run's log, on standard error: GitHub Actions workflow commands in a CI
/// run, plain lines in a dry run.
///
/// Much of what it writes comes from the pull request (file names, commit
/// subjects, the summary's findings), so in a CI run it never lets that
/// text pass for a workflow command, which could mask values, end a group,
/// or add annotations, and in a dry run it escapes the control characters
/// that could rewrite the terminal.
struct Log: Sendable {
    var mode: Run.Mode
    var console: Console
    /// Makes the token that pauses workflow commands around untrusted text.
    var makeToken: @Sendable () -> String = RunnerOutput.newStopToken

    /// Writes `text` as lines. In a CI run, text that could pass for a
    /// workflow command is wrapped in `::stop-commands::`.
    func write(_ text: String) {
        guard mode == .actions else {
            console.writeError(Self.terminated(Self.readable(text)))
            return
        }
        guard RunnerOutput.couldHoldCommands(text) else {
            console.writeError(Self.terminated(text))
            return
        }
        let token = makeToken()
        console.writeError("::stop-commands::\(token)\n\(Self.terminated(text))::\(token)::\n")
    }

    /// A notice: an annotation on the run in CI, a `notice:` line in a dry
    /// run.
    func notice(_ text: String) {
        annotate("notice", text)
    }

    /// A warning: an annotation on the run in CI, a `warning:` line in a
    /// dry run.
    func warning(_ text: String) {
        annotate("warning", text)
    }

    /// An error: an annotation on the run in CI, an `error:` line in a dry
    /// run.
    func error(_ text: String) {
        annotate("error", text)
    }

    /// Runs `body` with what it logs folded under `title` in CI. GitHub
    /// doesn't nest groups, so neither may callers.
    func group<Result, Failure: Error>(
        _ title: String,
        _ body: () async throws(Failure) -> Result
    ) async throws(Failure) -> Result {
        guard mode == .actions else { return try await body() }
        console.writeError("::group::\(RunnerOutput.escapedData(title))\n")
        defer { console.writeError("::endgroup::\n") }
        return try await body()
    }

    private func annotate(_ command: String, _ text: String) {
        switch mode {
        case .actions: console.writeError("::\(command) title=Steward::\(RunnerOutput.escapedData(text))\n")
        case .dryRun: console.writeError(Self.terminated(Self.readable("\(command): \(text)")))
        }
    }

    /// `text` for a terminal, as a dry run shows it: lines and tabs as they
    /// are, any other control character escaped, and a workflow command's
    /// syntax broken, since a dry run's output may still land in a log.
    static func readable(_ text: String) -> String {
        text.escapedForReading(keeping: ["\n", "\t"])
    }

    private static func terminated(_ text: String) -> String {
        text.utf8.last == UInt8(ascii: "\n") ? text : text + "\n"
    }
}
