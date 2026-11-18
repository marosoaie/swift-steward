extension Context {
    /// The context a run in GitHub Actions builds for a pull request with
    /// this diff, for testing rules.
    ///
    /// The diff goes through the parser a real run uses, with the same
    /// options, so `git.diff` and the file lists are what a run sees for
    /// that text. Give it as `git diff` writes it, from `diff --git` on;
    /// lines that are only a space may lose it, as editors trim them.
    ///
    /// The run is in `.actions` mode, built on the head commit, with
    /// GitHub's URLs. Its `files` reads `files` at the head, and nothing
    /// at the merge base. Every part is a `var`, so a test changes what
    /// it needs afterwards, such as `run.mode`, `run.builtCommit`, or
    /// `files`, to a `RepositoryFiles` of its own, which isn't checked.
    ///
    /// - Parameters:
    ///   - diff: The pull request's diff, from the merge base to the head.
    ///   - files: Files as the head commit has them, by path, for
    ///     `contents(ofFileAt:at:limit:)`. Each one the diff changes must
    ///     hold the diff's context and added lines at the numbers its hunk
    ///     headers give, and end in a line break unless the diff says it
    ///     doesn't. One the diff creates holds its lines and nothing more,
    ///     as does one whose last line, without a newline, the diff deletes:
    ///     the file ends with that hunk. A hunk that only deletes, as
    ///     `-U0` writes one, keeps the line before what it deletes, which
    ///     the file has, with its newline.
    ///     None may be a file the diff deletes, renames away, or makes a
    ///     symbolic link or a submodule. Files the diff doesn't touch
    ///     aren't checked.
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
    /// - Throws: `FixtureError` when the parser reports damage in `diff`,
    ///   or a file disagrees with it.
    public static func fixture(
        diff: String,
        files: [String: String] = [:],
        pullRequest: PullRequest? = nil,
        commits: [Commit]? = nil,
        workspace: String = "/workspace"
    ) throws(FixtureError) -> Context {
        let parsed = Diff(diff: diff)
        guard parsed.damage.isEmpty else { throw FixtureError(damage: parsed.damage) }
        let contents = files.mapValues { Array($0.utf8) }
        let mismatches = FixtureError.mismatches(between: parsed, and: contents)
        guard mismatches.isEmpty else { throw FixtureError(mismatches: mismatches) }
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
            ),
            files: FakeRepositoryFiles([request.head.commit: contents])
        )
    }
}
