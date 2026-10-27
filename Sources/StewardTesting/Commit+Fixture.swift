import Foundation

extension Commit {
    /// A commit for a test, with a default for every field: the default
    /// pull request's head commit, `4ead4ead…`, on its base commit,
    /// `ba5eba5e…`, with the subject "Add a feature", no body, and
    /// `Signature.fixture()` as author and committer.
    public static func fixture(
        sha: String = FixtureDefaults.headCommit,
        parents: [String] = [FixtureDefaults.baseCommit],
        author: Signature = .fixture(),
        committer: Signature = .fixture(),
        subject: String = "Add a feature",
        body: String = ""
    ) -> Commit {
        Commit(sha: sha, parents: parents, author: author, committer: committer, subject: subject, body: body)
    }
}

extension Commit.Signature {
    /// A signature for a test: Octocat, `octocat@example.com`, at
    /// 2026-01-01 00:00:00 UTC unless given.
    public static func fixture(
        name: String = "Octocat",
        email: String = "octocat@example.com",
        date: Date = FixtureDefaults.date
    ) -> Commit.Signature {
        Commit.Signature(name: name, email: email, date: date)
    }
}
