import PullRequestHosting

/// A pull request's summary comment, kept current through a host
/// (docs/danger.md, sections 5 and 6): created on the first run with
/// findings, updated in place after that, and never posted for a pull
/// request that's had none.
///
/// Posting lists the summary comments, re-reads the pull request, and
/// writes:
///
/// - With no summary comment yet, it creates one, unless there are no
///   findings: a clean pull request gets no comment.
/// - With one, it updates it, to "No findings" when there are none, so
///   reviewers find the resolution where they saw the failures. When it
///   was deleted since it was listed, it creates a new one.
/// - With several, after two runs raced to create one, it updates the
///   oldest and deletes the rest.
/// - When the pull request's head is no longer the commit the summary
///   describes, it writes nothing, or nothing more when a retry finds it
///   so: a newer run will post.
///
/// A request that fails in a way waiting can fix, a rate limit, a server
/// error, or a lost connection, is tried once more after a pause (see
/// `pause(before:)`). A write, a deletion included, re-reads the pull
/// request before its retry, since a newer run may have posted during the
/// pause. So a comment whose
/// creation went through but whose response was lost can be created
/// twice; the next run deletes the duplicate.
struct StickyComment: Sendable {
    /// What posting did.
    enum Outcome: Sendable {
        /// Posted the first summary comment.
        case created(SummaryComment)
        /// Updated the summary comment, and deleted this many duplicates.
        case updated(SummaryComment, deletedDuplicates: Int)
        /// There were no findings and no summary comment to clear.
        case nothingToPost
        /// The pull request's head moved on to this commit, so posting
        /// stopped: before its first write, or before a write's retry.
        case stale(head: String)
        /// A request failed, even after its retry when it got one.
        case failed(any Error)
    }

    /// The longest pause Steward makes before a retry. A host asking for a
    /// longer wait gets no retry.
    static let longestPause = Duration.seconds(60)
    /// The pause before retrying a server error or a lost connection.
    static let shortPause = Duration.seconds(2)

    var host: any PullRequestHost
    var pullRequest: Int
    /// The SHA of the head commit the summary describes.
    var headCommit: String
    var log: Log
    var sleep: @Sendable (Duration) async throws -> Void

    /// Posts `summary`, cut to what the host takes, with a cut line that
    /// sends readers to `elsewhere` for the rest, and logs what happened:
    /// a failure as a warning. Only cancellation throws; every other
    /// failure is the `failed` outcome.
    func post(_ summary: Summary, elsewhere: Summary.Elsewhere) async throws(CancellationError) -> Outcome {
        let outcome: Outcome
        do {
            outcome = try await write(summary, elsewhere: elsewhere)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            outcome = .failed(error)
        }
        logOutcome(outcome, elsewhere: elsewhere)
        return outcome
    }

    /// The head the pull request moved on to, which stops a posting.
    private struct MovedHead: Error {
        let head: String
    }

    private func write(_ summary: Summary, elsewhere: Summary.Elsewhere) async throws -> Outcome {
        let comments = try await retrying { try await host.summaryComments(onPullRequest: pullRequest) }
        if comments.isEmpty, summary.report.findings.isEmpty { return .nothingToPost }
        do {
            // Checked just before writing: a run for an older commit that
            // finishes last mustn't overwrite a newer run's summary.
            try await checkHead()
            let text = summary.text(fitting: host.maximumSummarySize, elsewhere: elsewhere)
            let create = { () async throws -> Outcome in
                .created(try await retrying(checkingHead: true) {
                    try await host.createSummaryComment(onPullRequest: pullRequest, body: text)
                })
            }
            guard let oldest = comments.first else { return try await create() }
            let duplicates = comments.dropFirst()
            // Written before the duplicates go, so a failure loses nothing.
            let outcome: Outcome
            do {
                let updated = try await retrying(checkingHead: true) {
                    try await host.updateSummaryComment(oldest.id, body: text)
                }
                outcome = .updated(updated, deletedDuplicates: duplicates.count)
            } catch let error as PullRequestHostError where error.kind == .notFound {
                log.write("""
                    The summary comment \(oldest.webURL) is gone since it was found, so Steward posts a new one.
                    """)
                outcome = try await create()
            }
            try await duplicates.asyncForEach { duplicate in
                // Checked too: after a newer run updated a duplicate whose
                // oldest was deleted in the pause, it's that run's summary.
                try await retrying(checkingHead: true) { try await host.deleteSummaryComment(duplicate.id) }
            }
            return outcome
        } catch let moved as MovedHead {
            return .stale(head: moved.head)
        }
    }

    /// Throws `MovedHead` when the pull request's head is no longer
    /// `headCommit`.
    private func checkHead() async throws {
        let head = try await retrying { try await host.pullRequest(number: pullRequest) }.head.commit
        guard head.lowercased() == headCommit.lowercased() else { throw MovedHead(head: head) }
    }

    /// Runs `request`, and once more after a pause when it fails in a way
    /// waiting can fix; with `checkingHead`, only if the pull request's
    /// head is still `headCommit` after the pause.
    private func retrying<Value>(
        checkingHead: Bool = false,
        _ request: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await request()
        } catch let error as PullRequestHostError {
            guard let pause = Self.pause(before: error) else { throw error }
            log.write("\(error). Trying again in \(Self.seconds(pause)).")
            try await sleep(pause)
            if checkingHead {
                try await checkHead()
            }
            return try await request()
        }
    }

    /// How long to wait before retrying after `error`, or nil when retrying
    /// can't help, or the host asks for a longer wait than `longestPause`,
    /// before which a retry would go against its wishes.
    ///
    /// Rate limits wait as long as the host asks, or a minute when it
    /// doesn't say, as GitHub asks for its secondary limits; server errors
    /// and lost connections wait `shortPause`.
    static func pause(before error: PullRequestHostError) -> Duration? {
        let pause: Duration
        switch error.kind {
        case .rateLimited: pause = error.retryAfter ?? longestPause
        case .serverError, .network: pause = error.retryAfter ?? shortPause
        case .notFound, .unauthorized, .forbidden, .rejected, .unexpectedStatus, .malformedResponse: return nil
        }
        return pause <= longestPause ? pause : nil
    }

    private static func seconds(_ duration: Duration) -> String {
        let seconds = duration.components.seconds + (duration.components.attoseconds > 0 ? 1 : 0)
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    /// Logs what posting did: a failure as a warning.
    private func logOutcome(_ outcome: Outcome, elsewhere: Summary.Elsewhere) {
        switch outcome {
        case .created(let comment):
            log.write("Posted the summary comment: \(comment.webURL)")
        case .updated(let comment, let deleted):
            let duplicates = switch deleted {
            case 0: ""
            case 1: ", and deleted 1 duplicate"
            default: ", and deleted \(deleted) duplicates"
            }
            log.write("Updated the summary comment: \(comment.webURL)\(duplicates)")
        case .nothingToPost:
            log.write("No findings, and no summary comment to update: nothing to post.")
        case .stale(let head):
            log.write("""
                The pull request's head is \(head) now, not \(headCommit), so this run stops posting: \
                the run for the newer commit posts its summary.
                """)
        case .failed(let error):
            log.warning(Self.warning(for: error, elsewhere: elsewhere))
        }
    }

    /// The warning for a posting that failed with `error`, with the fix
    /// when there's one, and where the findings are instead: the log, and
    /// `elsewhere`.
    static func warning(for error: any Error, elsewhere: Summary.Elsewhere) -> String {
        let hostError = error as? PullRequestHostError
        let asksTooLong = hostError?.retryAfter.map { $0 > longestPause } == true
        let advice: String? = switch hostError?.kind {
        case .forbidden?:
            """
            The token needs permission to comment: give the job `pull-requests: write` under `permissions:`. \
            Dependabot's pull requests always get a read-only token, so skip Steward on them.
            """
        case .unauthorized?:
            "Check the token in GITHUB_TOKEN."
        case .rateLimited? where asksTooLong, .serverError? where asksTooLong:
            hostError?.retryAfter.map {
                "GitHub asks to wait \(seconds($0)) before trying again, longer than Steward waits."
            }
        default:
            nil
        }
        let failure = "Couldn't post the summary comment: \(String(errorDescription: error))."
        return [failure, advice, elsewhere.findingsSentence]
            .compactMap(\.self)
            .joined(separator: " ")
    }
}

private extension Sequence {
    /// Runs `body` on each element in turn, waiting for each to finish.
    func asyncForEach(_ body: (Element) async throws -> Void) async rethrows {
        // Imperative: `forEach` takes no async closure, and the requests
        // must go one at a time.
        for element in self {
            try await body(element)
        }
    }
}
