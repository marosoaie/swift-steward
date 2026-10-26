import Foundation
@testable import Steward
import Testing

/// `GITHUB_SHA` is the merge commit, which a workflow that checks out the
/// pull request's head never fetches.
@Suite("Which commit a context takes as the built one")
struct BuiltCommitTests {
    @Test("a checkout of the head without the merge commit takes the head as built, with the identity map")
    func headCheckedOut() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let clone = try Self.cloneWithoutMergeCommit(of: fixture)
        defer { clone.remove() }
        try clone.git(["switch", "--quiet", "--detach", fixture.head])

        let context = try await Context.actions(environment: clone.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        ))
        #expect(context.run.builtCommit == fixture.head)
        #expect(context.run.lineMap == .identity)
        let original = try await Context.actions(environment: fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head
        ))
        #expect(context.git == original.git)
    }

    @Test("with neither the merge commit nor the head checked out, the built commit is refused", arguments: [
        "the base", "an earlier commit of the pull request",
    ])
    func otherCheckedOut(checkout: String) async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let clone = try Self.cloneWithoutMergeCommit(of: fixture)
        defer { clone.remove() }
        let commit = checkout == "the base" ? fixture.base : fixture.commits[0]
        try clone.git(["switch", "--quiet", "--detach", commit])

        let environment = try clone.actionsEnvironment(base: fixture.base, head: fixture.head, built: fixture.built)
        let error = await #expect(throws: ContextError.missingCommit(.built, sha: fixture.built)) {
            try await Context.actions(environment: environment)
        }
        #expect(error?.description.contains("Neither the merge commit nor the pull request's head") == true)
    }

    @Test("an unborn HEAD names no commit, so the built commit is refused")
    func unbornHead() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let repository = try TestRepository()
        defer { repository.remove() }
        try repository.git([
            "fetch", "--quiet", fixture.repository.path,
            "feature:refs/remotes/origin/feature", "main:refs/remotes/origin/main",
        ])

        let environment = try repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        )
        await #expect(throws: ContextError.missingCommit(.built, sha: fixture.built)) {
            try await Context.actions(environment: environment)
        }
    }

    @Test("a checkout that has the merge commit takes it as built, whatever HEAD is")
    func mergeCommitPresent() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        try fixture.repository.git(["switch", "--quiet", "--detach", fixture.head])
        let context = try await Context.actions(environment: fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        ))
        #expect(context.run.builtCommit == fixture.built)
        #expect(context.run.lineMap != .identity)
    }

    /// A clone with the pull request's branch and the base branch, as
    /// `actions/checkout` leaves one that checks out `head.sha` with
    /// `fetch-depth: 0`: the merge commit, on no branch, isn't fetched.
    private static func cloneWithoutMergeCommit(of fixture: PullRequestFixture) throws -> TestRepository {
        let clone = try TestRepository(cloning: fixture.repository, options: ["--single-branch", "--branch=feature"])
        try clone.git(["fetch", "--quiet", "origin", "main:refs/remotes/origin/main"])
        #expect(throws: (any Error).self) {
            try clone.git(["rev-parse", "--verify", "--quiet", "\(fixture.built)^{commit}"])
        }
        return clone
    }
}
