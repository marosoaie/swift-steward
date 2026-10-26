import Foundation
@testable import Steward
import Testing

@Suite("The history a context needs from the checkout")
struct ContextHistoryTests {
    @Test("a commit the checkout lacks is reported as history too shallow", arguments: [
        ContextError.CommitRole.base, .head, .built,
    ])
    func missingCommit(role: ContextError.CommitRole) async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        let absent = String(repeating: "0123456789", count: 4)
        let environment = try repository.actionsEnvironment(
            base: role == .base ? absent : commit,
            head: role == .head ? absent : commit,
            built: role == .built ? absent : commit
        )
        await #expect(throws: ContextError.missingCommit(role, sha: absent)) {
            try await Context.actions(environment: environment)
        }
    }

    @Test("actions/checkout's default depth of 1 has only the built commit")
    func depthOne() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let clone = try TestRepository(cloning: fixture.repository, options: ["--depth=1", "--branch=merge"])
        defer { clone.remove() }
        let environment = try clone.actionsEnvironment(base: fixture.base, head: fixture.head, built: fixture.built)
        let error = await #expect(throws: ContextError.missingCommit(.base, sha: fixture.base)) {
            try await Context.actions(environment: environment)
        }
        #expect(error?.description.contains("fetch-depth: 0") == true)
    }

    @Test("with the base and head but not their merge base, the history is too shallow")
    func shallowMergeBase() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let clone = try TestRepository(cloning: fixture.repository, options: ["--depth=1", "--no-single-branch"])
        defer { clone.remove() }
        let environment = try clone.actionsEnvironment(base: fixture.base, head: fixture.head, built: fixture.built)
        let error = await #expect(
            throws: ContextError.noMergeBase(base: fixture.base, head: fixture.head, isShallow: true)
        ) {
            try await Context.actions(environment: environment)
        }
        #expect(error?.description.contains("too shallow") == true)
    }

    @Test("a full history with enough depth builds the same context as the original")
    func deepEnoughClone() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let clone = try TestRepository(cloning: fixture.repository, options: ["--depth=3", "--no-single-branch"])
        defer { clone.remove() }
        let original = try await Context.actions(environment: fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        ))
        let cloned = try await Context.actions(environment: clone.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        ))
        #expect(cloned.git == original.git)
        #expect(cloned.run.lineMap == original.run.lineMap)
    }

    @Test("a base and head with no common history are refused")
    func unrelatedHistories() async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        try repository.git(["switch", "--quiet", "--orphan", "unrelated"])
        try repository.write("other\n", to: "other.swift")
        let other = try repository.commit("Unrelated", at: PullRequestFixture.time + 10)
        let environment = try repository.actionsEnvironment(base: commit, head: other)
        let error = await #expect(throws: ContextError.noMergeBase(base: commit, head: other, isShallow: false)) {
            try await Context.actions(environment: environment)
        }
        #expect(error?.description.contains("share no history") == true)
    }

    @Test("a workspace that isn't a repository is a git failure, not a missing commit")
    func notARepository() async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        var environment = try repository.actionsEnvironment(base: commit, head: commit)
        environment["GITHUB_WORKSPACE"] = repository.root.path
        let error = await #expect(throws: ContextError.self) {
            try await Context.actions(environment: environment)
        }
        guard case .gitFailed(_, let status, let message) = error else {
            Issue.record("expected gitFailed, got \(String(describing: error))")
            return
        }
        #expect(status == 128)
        #expect(message.contains("not a git repository"))
    }
}
