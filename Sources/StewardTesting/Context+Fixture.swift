extension Context {
    /// A diff given to `fixture(diff:pullRequest:commits:workspace:)` isn't
    /// one git writes: the parser reported damage in it, so the context
    /// would differ from a real run's.
    ///
    /// Usually a hunk header whose line counts don't match its lines.
    public struct FixtureError: Error, Sendable, Equatable, CustomStringConvertible {
        /// What the parser reported, in diff order.
        public var damage: [DamageReport]

        /// Creates an error for the damage the parser reported.
        public init(damage: [DamageReport]) {
            self.damage = damage
        }

        /// Each damage report on a line, after a sentence saying what's
        /// wrong.
        public var description: String {
            """
            Context.fixture(diff:) needs a diff git could write, and this one is damaged; \
            check each hunk header's line counts against its lines.
            \(damage.map(\.sentence).joined(separator: "\n"))
            """
        }
    }

    /// The context a run in GitHub Actions builds for a pull request with
    /// this diff, for testing rules.
    ///
    /// The diff goes through the parser a real run uses, with the same
    /// options, so `git.diff` and the file lists are what a run sees for
    /// that text. Give it as `git diff` writes it, from `diff --git` on;
    /// lines that are only a space may lose it, as editors trim them.
    ///
    /// The run is in `.actions` mode, built on the head commit, with
    /// GitHub's URLs. Every part is a `var`, so a test changes what it
    /// needs afterwards, such as `run.mode` or `run.builtCommit`.
    ///
    /// - Parameters:
    ///   - diff: The pull request's diff, from the merge base to the head.
    ///   - pullRequest: The pull request. Nil for `PullRequest.fixture()`
    ///     with its additions, deletions, changed files, and commits
    ///     counted from `diff` and `commits` as GitHub counts them; a pull
    ///     request given is used as it is.
    ///   - commits: The pull request's commits, oldest first. Nil for
    ///     one: the pull request's head commit on its base commit, its
    ///     title as the subject and its description as the body.
    ///   - workspace: The checkout's root, where a rule reads files such
    ///     as build logs.
    /// - Returns: The context, with `git.mergeBase` and `git.head` the pull
    ///   request's base and head commits.
    /// - Throws: `FixtureError` when the parser reports damage in `diff`.
    public static func fixture(
        diff: String,
        pullRequest: PullRequest? = nil,
        commits: [Commit]? = nil,
        workspace: String = "/workspace"
    ) throws(FixtureError) -> Context {
        let parsed = Diff(diff: diff)
        guard parsed.damage.isEmpty else { throw FixtureError(damage: parsed.damage) }
        let request = pullRequest ?? .fixture()
        let changes = GitChanges(
            diff: parsed,
            commits: commits ?? [
                .fixture(
                    sha: request.head.commit,
                    parents: [request.base.commit],
                    subject: request.title,
                    body: request.body
                ),
            ],
            mergeBase: request.base.commit,
            head: request.head.commit
        )
        return Context(
            pullRequest: pullRequest ?? request.sized(for: changes),
            git: changes,
            run: Run(
                mode: .actions,
                workspace: workspace,
                builtCommit: request.head.commit,
                lineMap: .identity,
                apiURL: FixtureDefaults.apiURL,
                serverURL: FixtureDefaults.serverURL
            )
        )
    }
}
