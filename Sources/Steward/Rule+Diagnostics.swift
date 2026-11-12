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
    /// `steward filter --repo-root <workspace>` matches them, except that a
    /// path naming a file in the checkout is that file: a diagnostic in an
    /// untouched `Other/Foo.swift` never lands on a changed `Foo.swift`. A
    /// path the checkout has no file at resolves by its longest suffix among
    /// the pull request's paths, as `filter` resolves it.
    ///
    /// A diagnostic at or above `severity` is a failure, as one fails
    /// `steward filter --fail-on <severity>`; below it, a warning is a
    /// warning and a note a message. The default, `.error`, fails on errors
    /// alone; `.warning` fails on warnings too, as a workflow that gates on
    /// warnings does. Each finding's text is the tool's message, escaped so
    /// it renders as written, with its rule, if any, as a code span. A
    /// diagnostic that several reports give alike in every part, column
    /// included, is reported once, from the first of them: two builds of
    /// one package, for two platforms, warn twice about the same line. The
    /// log says, for each report, how many diagnostics it held, matched,
    /// dropped, and left out as an earlier report's.
    ///
    /// A build log's errors that aren't on lines the pull request adds are
    /// one more failure, without a location, listing the first five: a
    /// build can fail on lines the pull request didn't change, or with no
    /// line at all, as on a linker's undefined symbol or Xcode's "Multiple
    /// commands produce". Errors without a location count only in a log
    /// without located ones, since a build system repeats a compiler's
    /// errors without one. A lint report's errors elsewhere are the norm,
    /// so they're left out.
    ///
    /// A report that can't be read, or whose `builtAt:` commit the
    /// checkout doesn't have, is one failure; the other reports are still
    /// read. Content a report's parser doesn't recognize, a malformed
    /// report included, gives no diagnostics.
    ///
    /// `name` names the rule in the report and the log; give each of two
    /// such rules its own.
    public static func diagnosticsOnChangedLines(
        in sources: [DiagnosticSource],
        failingOn severity: DiagnosticSeverity = .error,
        named name: String = "Diagnostics on changed lines"
    ) -> Rule {
        Rule(name) { context, log in
            try await ChangedLineDiagnostics.findings(for: sources, failingOn: severity, in: context, log: log)
        }
    }
}
