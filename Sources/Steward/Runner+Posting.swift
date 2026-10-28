import Foundation
import PullRequestHosting

extension Runner {
    /// Shows the summary: in CI, in the log, appended to the job summary,
    /// and posted; in a dry run, on standard output. Says how the run
    /// should exit for it: broken when it was cancelled, or when posting
    /// failed with `--fail-on-post-error`.
    ///
    /// Where the job summary or the comment is cut short, its last line
    /// sends readers to where all of it is: for the comment, the job
    /// summary when all of it went there; otherwise `fallback`.
    func publish(
        _ summary: Summary,
        in context: Context,
        options: Options,
        fallback: Summary.Elsewhere,
        log: Log
    ) async -> ExitStatus {
        let text = summary.text
        switch context.run.mode {
        case .dryRun:
            console.writeOutput(text)
            return .clean
        case .actions:
            await log.group("Summary") { log.write(text) }
            let isJobSummaryWhole = appendToJobSummary(summary, whole: text, fallback: fallback, log: log)
            return await post(summary, in: context, options: options,
                              elsewhere: isJobSummaryWhole ? .jobSummary : fallback, log: log)
        }
    }

    /// Appends the summary to the file at `GITHUB_STEP_SUMMARY`, which
    /// GitHub shows on the run's page, cut to fit in what's left of
    /// `jobSummaryLimit`, and says whether all of it went in. Without it,
    /// the findings are still in the log, so a failure here is only a
    /// warning.
    private func appendToJobSummary(
        _ summary: Summary,
        whole: String,
        fallback: Summary.Elsewhere,
        log: Log
    ) -> Bool {
        guard let path = environment["GITHUB_STEP_SUMMARY"], !path.isEmpty else {
            log.warning("GITHUB_STEP_SUMMARY isn't set, so the findings are in this log only.")
            return false
        }
        do {
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
                }
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let existing = Int(clamping: try handle.seekToEnd())
            // A blank line ends whatever came before, even a table whose
            // last line has no line break.
            let separator = existing > 0 ? "\n\n" : ""
            let budget = Self.jobSummaryLimit - existing - separator.utf8.count
            let text = summary.text(fitting: budget, elsewhere: fallback)
            guard text.utf8.count <= budget else {
                log.warning("""
                    The job summary at \(path) already holds \(existing) bytes, so the summary doesn't fit \
                    in the 1 MiB GitHub shows, and Steward leaves it out. \(fallback.findingsSentence)
                    """)
                return false
            }
            try handle.write(contentsOf: Data((separator + text).utf8))
            return text == whole
        } catch {
            log.warning("Couldn't write the job summary to \(path): \(String(errorDescription: error))")
            return false
        }
    }

    /// Posts the summary as the pull request's summary comment, unless the
    /// pull request comes from a fork, and says how the run should exit
    /// for it. A comment cut short sends readers to `elsewhere`.
    private func post(
        _ summary: Summary,
        in context: Context,
        options: Options,
        elsewhere: Summary.Elsewhere,
        log: Log
    ) async -> ExitStatus {
        let pullRequest = context.pullRequest
        guard !pullRequest.isFromFork else {
            // A fork's runs get a read-only token. Not a failure: the
            // findings still set the check's status and fill the job summary.
            log.notice("""
                The pull request comes from \(pullRequest.head.repository), a fork, whose workflow runs get a \
                read-only token, so Steward doesn't post the summary comment. \(elsewhere.findingsSentence)
                """)
            return .clean
        }
        let failed: ExitStatus = options.failsOnPostError ? .broken : .clean
        guard let token = environment["GITHUB_TOKEN"], !token.isEmpty else {
            log.warning("""
                GITHUB_TOKEN isn't set, so Steward can't post the summary comment: give the step \
                `env: GITHUB_TOKEN: ${{ github.token }}`, or, with steward-action, a `token` input that \
                isn't empty. \(elsewhere.findingsSentence)
                """)
            return failed
        }
        guard let repository = RepositoryName(pullRequest.base.repository) else {
            log.warning("""
                The event names the repository "\(pullRequest.base.repository)", which isn't owner/name, \
                so Steward can't post the summary comment. \(elsewhere.findingsSentence)
                """)
            return failed
        }
        let annotationCheck = repository.owner // TEMPORARY: a warning for the annotations check
        let comment = StickyComment(
            host: makeHost(context.run.apiURL, repository.owner, repository.name, token, options.summaryAuthor),
            pullRequest: pullRequest.number,
            headCommit: context.git.head,
            log: log,
            sleep: sleep
        )
        do {
            let outcome = try await log.group("Summary comment") { () async throws(CancellationError) in
                try await comment.post(summary, elsewhere: elsewhere)
            }
            guard case .failed = outcome else { return .clean }
            return failed
        } catch {
            log.error("The run was cancelled while posting the summary comment.")
            return .broken
        }
    }
}
