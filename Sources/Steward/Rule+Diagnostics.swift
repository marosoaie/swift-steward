extension Rule {
    /// A rule that reports the build and lint diagnostics on the lines the
    /// pull request adds, read from reports the workflow already wrote
    /// (docs/danger.md, section 3), as `steward filter` would.
    ///
    /// ```swift
    /// Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log"), .swiftLint("swiftlint.log")])
    /// ```
    ///
    /// Each diagnostic is mapped from the commit its report was built from
    /// to the head commit, `Run.lineMap`: one on a line the base branch or
    /// the merge changed has no place in the head and is dropped. The rest
    /// match the lines the pull request adds, at their head locations, as
    /// `steward filter --repo-root <workspace>` matches them. An error is a
    /// failure, a warning a warning, and a note a message; each finding's
    /// text is the tool's message, escaped so it renders as written, with
    /// its rule, if any, as a code span. The log says, for each report, how
    /// many diagnostics it held, matched, and dropped.
    ///
    /// A report that can't be read, or whose `builtAt:` commit the
    /// checkout doesn't have, is one failure; the other reports are still
    /// read. Content a report's parser doesn't recognize, a malformed
    /// report included, gives no diagnostics.
    public static func diagnosticsOnChangedLines(in sources: [DiagnosticSource]) -> Rule {
        Rule("Diagnostics on changed lines") { context, log in
            try await ChangedLineDiagnostics.findings(for: sources, in: context, log: log)
        }
    }
}
