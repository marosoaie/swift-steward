import Foundation

/// A run's log, on standard error: GitHub Actions workflow commands in a CI
/// run, plain lines in a dry run.
///
/// Much of what it writes comes from the pull request (file names, commit
/// subjects, the summary's findings), so in a CI run it never lets that
/// text pass for a workflow command, which could mask values, end a group,
/// or add annotations.
struct Log: Sendable {
    var mode: Run.Mode
    var console: Console
    /// Makes the token that pauses workflow commands around untrusted text.
    /// It must be unpredictable, or the text could end the pause itself.
    var makeToken: @Sendable () -> String = { UUID().uuidString }

    /// Writes `text` as lines. In a CI run, text that could pass for a
    /// workflow command is wrapped in `::stop-commands::`.
    func write(_ text: String) {
        guard mode == .actions, Self.couldHoldCommands(text) else {
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
        console.writeError("::group::\(Self.escapedData(title))\n")
        defer { console.writeError("::endgroup::\n") }
        return try await body()
    }

    private func annotate(_ command: String, _ text: String) {
        switch mode {
        case .actions: console.writeError("::\(command) title=Steward::\(Self.escapedData(text))\n")
        case .dryRun: console.writeError(Self.terminated("\(command): \(text)"))
        }
    }

    /// `text` as a workflow command's data, which must stay on the
    /// command's line.
    static func escapedData(_ text: String) -> String {
        escaped(text, isProperty: false)
    }

    /// `text` as the value of a workflow command's property, which must
    /// also not end the value (`,`) or the properties (`::`).
    static func escapedProperty(_ text: String) -> String {
        escaped(text, isProperty: true)
    }

    private static func escaped(_ text: String, isProperty: Bool) -> String {
        // Over scalars: "\r\n" is one Character, and both of its halves
        // need escaping, as does a `:` or `,` a combining mark follows.
        text.unicodeScalars.reduce(into: "") { escaped, scalar in
            switch scalar {
            case "%": escaped += "%25"
            case "\r": escaped += "%0D"
            case "\n": escaped += "%0A"
            case ":" where isProperty: escaped += "%3A"
            case "," where isProperty: escaped += "%2C"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
    }

    /// Whether the runner could read a line of `text` as a workflow
    /// command: one that starts with `::` once its leading whitespace is
    /// trimmed, as the runner trims it, or one with the older `##[` syntax,
    /// which the runner finds anywhere in a line. Both line breaks count,
    /// as they do for the runner.
    static func couldHoldCommands(_ text: String) -> Bool {
        text.unicodeScalars.contains("##[".unicodeScalars)
            || text.unicodeScalars
                .split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
                .contains { $0.drop { $0.properties.isWhitespace }.starts(with: "::".unicodeScalars) }
    }

    private static func terminated(_ text: String) -> String {
        text.utf8.last == UInt8(ascii: "\n") ? text : text + "\n"
    }
}
