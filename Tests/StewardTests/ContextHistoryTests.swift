import Foundation
@testable import Steward
import Testing

@Suite("The history a context needs from the checkout")
struct ContextHistoryTests {
    // A missing built commit is BuiltCommitTests': the head can stand in.
    @Test("a base or head commit the checkout lacks is reported as history too shallow", arguments: [
        ContextError.CommitRole.base, .head,
    ])
    func missingCommit(role: ContextError.CommitRole) async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        let absent = String(repeating: "0123456789", count: 4)
        let environment = try repository.actionsEnvironment(
            base: role == .base ? absent : commit,
            head: role == .head ? absent : commit,
            built: commit
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

    @Test("a merge of the base reaches a merge base past a shallow cut, so the commits cut off are refused")
    func truncatedHistory() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let time = PullRequestFixture.time
        try repository.write("start\n", to: "a.swift")
        try repository.commit("Start", at: time)
        try repository.git(["switch", "--quiet", "--create", "feature"])
        try repository.write("one\n", to: "b.swift")
        try repository.commit("First", at: time + 10)
        try repository.write("two\n", to: "b.swift")
        let second = try repository.commit("Second", at: time + 20)
        try repository.git(["switch", "--quiet", "main"])
        try repository.write("main\n", to: "c.swift")
        let base = try repository.commit("Main", at: time + 30)
        try repository.git(["switch", "--quiet", "feature"])
        try repository.merge("main", at: time + 40)
        try repository.write("three\n", to: "b.swift")
        let head = try repository.commit("Third", at: time + 50)
        let full = try await Context.actions(environment: repository.actionsEnvironment(base: base, head: head))
        #expect(full.git.commits.map(\.subject) == ["First", "Second", "Merge branch 'main' into feature", "Third"])

        // Third, the merge, then Second and Main with their parents cut
        // off: the merge base is Main, and First is gone.
        let clone = try TestRepository(cloning: repository, options: ["--depth=3", "--branch=feature"])
        defer { clone.remove() }
        let environment = try clone.actionsEnvironment(base: base, head: head)
        let error = await #expect(throws: ContextError.truncatedHistory(base: base, head: head, boundary: second)) {
            try await Context.actions(environment: environment)
        }
        #expect(error?.description.contains("fetch-depth: 0") == true)
    }

    @Test("a base on the shallow boundary would take in history it shares with the head, so it's refused")
    func baseOnBoundary() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let time = PullRequestFixture.time
        try repository.write("start\n", to: "a.swift")
        let root = try repository.commit("Start", at: time)
        try repository.git(["switch", "--quiet", "--create", "feature"])
        try repository.write("one\n", to: "b.swift")
        try repository.commit("First", at: time + 10)
        try repository.git(["switch", "--quiet", "main"])
        try repository.write("main\n", to: "c.swift")
        try repository.commit("Main", at: time + 20)
        try repository.write("more\n", to: "c.swift")
        let base = try repository.commit("More", at: time + 30)
        try repository.git(["switch", "--quiet", "feature"])
        try repository.merge("main", at: time + 40)
        try repository.write("two\n", to: "b.swift")
        let head = try repository.commit("Second", at: time + 50)
        // As a depth-limited fetch of the base leaves it: More's parents
        // are cut off, so Start no longer counts as the base's.
        let clone = try TestRepository(cloning: repository)
        defer { clone.remove() }
        try clone.write("\(base)\n", to: ".git/shallow")
        let environment = try clone.actionsEnvironment(base: base, head: head)
        let error = await #expect(throws: ContextError.truncatedHistory(base: base, head: head, boundary: root)) {
            try await Context.actions(environment: environment)
        }
        #expect(error?.description.contains("fetch-depth: 0") == true)
    }

    @Test("a cut on the base's side the head reaches past is refused, though every commit in the range has parents")
    func cutUnderSharedHistory() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let (base, head) = try Self.commitHistorySharedThroughFix(in: repository)
        let full = try await Context.actions(environment: repository.actionsEnvironment(base: base, head: head))
        #expect(full.git.commits.map(\.subject) == ["Second", "Merge branch 'main' into feature", "Third"])

        // As a depth-limited fetch of the base can leave it: with Fix's
        // parent cut off, First stops counting as the base's, and the range
        // takes it in down to Main, which the base still reaches.
        let fix = try repository.git(["rev-parse", "\(base)^2"])
        let clone = try TestRepository(cloning: repository)
        defer { clone.remove() }
        try clone.write("\(fix)\n", to: ".git/shallow")
        let environment = try clone.actionsEnvironment(base: base, head: head)
        await #expect(throws: ContextError.truncatedHistory(base: base, head: head, boundary: fix)) {
            try await Context.actions(environment: environment)
        }
    }

    @Test("a cut on the base's side below every commit the range starts from leaves the range whole")
    func cutBelowRange() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let (base, head) = try Self.commitHistorySharedThroughFix(in: repository)
        let full = try await Context.actions(environment: repository.actionsEnvironment(base: base, head: head))

        let main = try repository.git(["rev-parse", "\(base)^1"])
        let clone = try TestRepository(cloning: repository)
        defer { clone.remove() }
        try clone.write("\(main)\n", to: ".git/shallow")
        let cloned = try await Context.actions(environment: clone.actionsEnvironment(base: base, head: head))
        #expect(cloned.git == full.git)
    }

    /// Commits Start and Main on main, First on a feature branch, and Fix
    /// on top of First, merged into main as the base; then the feature's
    /// Second, a merge of main, and Third, the head. The base reaches First
    /// only through Fix, and the head directly too.
    private static func commitHistorySharedThroughFix(
        in repository: TestRepository
    ) throws -> (base: String, head: String) {
        let time = PullRequestFixture.time
        try repository.write("start\n", to: "a.swift")
        try repository.commit("Start", at: time)
        try repository.write("main\n", to: "a.swift")
        try repository.commit("Main", at: time + 10)
        try repository.git(["switch", "--quiet", "--create", "feature"])
        try repository.write("one\n", to: "b.swift")
        try repository.commit("First", at: time + 20)
        try repository.git(["switch", "--quiet", "--create", "fix"])
        try repository.write("fix\n", to: "c.swift")
        try repository.commit("Fix", at: time + 30)
        try repository.git(["switch", "--quiet", "main"])
        let base = try repository.merge("fix", at: time + 40)
        try repository.git(["switch", "--quiet", "feature"])
        try repository.write("two\n", to: "b.swift")
        try repository.commit("Second", at: time + 50)
        try repository.merge("main", at: time + 60)
        try repository.write("three\n", to: "b.swift")
        let head = try repository.commit("Third", at: time + 70)
        return (base, head)
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
        #expect(error?.description.contains("safe.directory") == false)
    }

    @Test("a checkout another user owns is a git failure that names the safe.directory fix")
    func dubiousOwnership() async throws {
        let (repository, _) = try TestRepository.singleCommit()
        defer { repository.remove() }
        // As root in a container sees the runner's checkout. Without global
        // or system configuration, so no safe.directory there trusts it.
        let git = Git(directory: repository.path, environment: ProcessInfo.processInfo.environment.merging([
            "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ]) { $1 })
        let error = await #expect(throws: ContextError.self) {
            try await git.commit(named: "HEAD")
        }
        guard case .gitFailed(_, let status, let message) = error else {
            Issue.record("expected gitFailed, got \(String(describing: error))")
            return
        }
        #expect(status == 128)
        #expect(message.contains("dubious ownership"))
        let remedy = #"git config --global --add safe.directory "$GITHUB_WORKSPACE""#
        #expect(error?.description.contains(remedy) == true, "\(error?.description ?? "")")
    }
}
