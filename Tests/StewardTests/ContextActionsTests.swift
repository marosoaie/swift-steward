import Foundation
import GitDiffKit
import PullRequestHosting
@testable import Steward
import Testing

@Suite("A GitHub Actions run's context")
struct ContextActionsTests {
    @Test("a pull request's context matches git: its files, diff, commits, merge base, and line map")
    func matchesGit() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let environment = try fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        )
        let context = try await Context.actions(environment: environment)

        let oracle = GitOracle(directory: fixture.repository.path)
        try oracle.verify(context.git, base: fixture.base)
        try oracle.verify(context.run.lineMap, head: fixture.head, built: fixture.built)
        #expect(context.git.mergeBase == fixture.forkPoint)
        #expect(context.git.head == fixture.head)
        #expect(context.git.commits.map(\.sha) == fixture.commits)
        #expect(context.git.createdFiles.sorted() == ["image.png", PullRequestFixture.quotedPath].sorted())
        #expect(context.git.deletedFiles == ["gone.swift"])
        #expect(context.git.renamedFiles == [GitChanges.Rename(from: "old.swift", to: "new.swift")])
        #expect(context.git.modifiedFiles.sorted() == ["a.swift", "moved.swift", "new.swift", "run.sh"])
        let first = try #require(context.git.commits.first)
        #expect(first.subject == "Change files")
        #expect(first.body == "With a body\nover two lines.")
        #expect(first.author.name == "Ada Lovelace")
        #expect(first.committer.email == "charles@example.com")
        #expect(first.author.date == Date(timeIntervalSince1970: TimeInterval(PullRequestFixture.time + 100)))
        #expect(first.parents == [fixture.forkPoint])
    }

    @Test("lines the base shifted or renamed map back to the head, and lines it added map nowhere")
    func lineMap() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let environment = try fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        )
        let map = try await Context.actions(environment: environment).run.lineMap
        #expect(map.headLocation(ofLine: 2, inFile: "a.swift") == nil)
        #expect(map.headLocation(ofLine: 13, inFile: "a.swift") == Location(path: "a.swift", line: 10))
        #expect(map.headLocation(ofLine: 1, inFile: "relocated.swift") == nil)
        #expect(map.headLocation(ofLine: 7, inFile: "relocated.swift") == Location(path: "moved.swift", line: 5))
        #expect(map.headPath(ofFile: "relocated.swift") == "moved.swift")
        #expect(map.headLocation(ofLine: 1, inFile: "new.swift") == Location(path: "new.swift", line: 1))
    }

    @Test("the run carries the workspace, the built commit, and github.com's URLs by default")
    func run() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let environment = try fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        )
        let context = try await Context.actions(environment: environment)
        #expect(context.run.mode == .actions)
        #expect(context.run.workspace == fixture.repository.path)
        #expect(context.run.builtCommit == fixture.built)
        #expect(context.run.apiURL == URL(string: "https://api.github.com"))
        #expect(context.run.serverURL == URL(string: "https://github.com"))
        #expect(context.pullRequest.number == 21)
        #expect(context.pullRequest.base.commit == fixture.base)
        #expect(context.pullRequest.head.commit == fixture.head)
    }

    @Test("GitHub Enterprise's API and server URLs carry through")
    func enterpriseURLs() async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        var environment = try repository.actionsEnvironment(base: commit, head: commit)
        environment["GITHUB_API_URL"] = "https://ghe.example.com/api/v3"
        environment["GITHUB_SERVER_URL"] = "https://ghe.example.com"
        let run = try await Context.actions(environment: environment).run
        #expect(run.apiURL == URL(string: "https://ghe.example.com/api/v3"))
        #expect(run.serverURL == URL(string: "https://ghe.example.com"))
    }

    @Test("when the built commit is the head, the line map is the identity")
    func builtHead() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let environment = try fixture.repository.actionsEnvironment(base: fixture.base, head: fixture.head)
        let context = try await Context.actions(environment: environment)
        #expect(context.run.lineMap == .identity)
        #expect(context.run.builtCommit == fixture.head)
    }

    @Test("a pull request with no changes yet has an empty diff and no commits")
    func noChanges() async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        let context = try await Context.actions(environment: repository.actionsEnvironment(base: commit, head: commit))
        #expect(context.git.diff.files.isEmpty)
        #expect(context.git.commits.isEmpty)
        #expect(context.git.mergeBase == commit)
    }

    @Test("a file that becomes a symlink is a deletion and a creation, as git's patch has it")
    func typeChange() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let time = PullRequestFixture.time
        try repository.write("target\n", to: "target.swift")
        try repository.write("one\n", to: "file.swift")
        try repository.write("two\n", to: "other.swift")
        let base = try repository.commit("Start", at: time)
        try repository.git(["switch", "--quiet", "--create", "feature"])
        try FileManager.default.removeItem(at: repository.url.appendingPathComponent("file.swift"))
        try FileManager.default.createSymbolicLink(
            at: repository.url.appendingPathComponent("file.swift"),
            withDestinationURL: URL(fileURLWithPath: "target.swift")
        )
        let head = try repository.commit("Link the file", at: time + 10)
        // The built tree has a type change against the head too.
        try repository.git(["switch", "--quiet", "--create", "merge", "main"])
        try FileManager.default.removeItem(at: repository.url.appendingPathComponent("other.swift"))
        try FileManager.default.createSymbolicLink(
            at: repository.url.appendingPathComponent("other.swift"),
            withDestinationURL: URL(fileURLWithPath: "target.swift")
        )
        try repository.commit("Link the other file", at: time + 20)
        let built = try repository.merge("feature", at: time + 30)

        let context = try await Context.actions(
            environment: repository.actionsEnvironment(base: base, head: head, built: built)
        )
        #expect(context.git.createdFiles == ["file.swift"])
        #expect(context.git.deletedFiles == ["file.swift"])
        #expect(context.git.modifiedFiles.isEmpty)
        let oracle = GitOracle(directory: repository.path)
        try oracle.verify(context.git, base: base)
        try oracle.verify(context.run.lineMap, head: head, built: built)
    }

    @Test("SHAs in capitals read as git prints them")
    func uppercaseSHAs() async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        let environment = try repository.actionsEnvironment(base: commit.uppercased(), head: commit.uppercased())
        let context = try await Context.actions(environment: environment)
        #expect(context.git.head == commit)
        #expect(context.run.builtCommit == commit)
    }
}
