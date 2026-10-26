/// A build log or a linter's report that the workflow already wrote, for
/// `Rule.diagnosticsOnChangedLines(in:)` to read.
///
/// ```swift
/// Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log"), .swiftLint("swiftlint.log")])
/// ```
///
/// A relative path starts from the checkout's root, `Run.workspace`, not
/// from the current directory. A report's line numbers are taken to be the
/// built commit's, `Run.builtCommit`, which in a `pull_request` workflow is
/// the merge commit Actions checks out. A report made from another
/// checkout, in another job for example, names the commit it was made from
/// with `builtAt:`, a SHA or anything else git resolves to a commit in the
/// checkout.
public struct DiagnosticSource: Sendable, Hashable {
    /// The tools whose output Steward reads, each with the parser
    /// `steward filter --tool` uses for it.
    enum Tool: Sendable, Hashable {
        case xcodebuild
        case swiftLint
        case swiftFormat
        case sonar
    }

    var tool: Tool
    /// As the Dangerfile gave it.
    var path: String
    /// The commit the report's lines refer to, when it isn't the run's
    /// built commit.
    var builtCommit: String?

    /// The output of `xcodebuild`, `swift build`, `swiftc`, or clang:
    /// clang-style diagnostic lines (`path:line:column: warning: message`)
    /// anywhere in the log, with a clang warning flag such as
    /// `-Wunused-variable` taken as the rule.
    public static func xcodebuild(_ path: String, builtAt commit: String? = nil) -> DiagnosticSource {
        DiagnosticSource(tool: .xcodebuild, path: path, builtCommit: commit)
    }

    /// The output of `swiftlint lint` with its default reporter (`xcode`),
    /// which ends each violation with its rule's identifier, such as
    /// `(line_length)`. SwiftLint's other reporters, JSON included, aren't
    /// read.
    public static func swiftLint(_ path: String, builtAt commit: String? = nil) -> DiagnosticSource {
        DiagnosticSource(tool: .swiftLint, path: path, builtCommit: commit)
    }

    /// The output of `swiftformat --lint`, which starts each message with
    /// its rule's name, such as `(indent)`.
    public static func swiftFormat(_ path: String, builtAt commit: String? = nil) -> DiagnosticSource {
        DiagnosticSource(tool: .swiftFormat, path: path, builtCommit: commit)
    }

    /// A SonarQube issues report: the JSON of `GET /api/issues/search`, or
    /// its pages' issues merged into one array. Issues without a line, and
    /// resolved ones, are skipped; paths are relative to
    /// `sonar.projectBaseDir`.
    public static func sonar(_ path: String, builtAt commit: String? = nil) -> DiagnosticSource {
        DiagnosticSource(tool: .sonar, path: path, builtCommit: commit)
    }
}
