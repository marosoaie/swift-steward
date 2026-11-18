import Foundation
import GitDiffKit
@testable import Steward
import Testing

/// A rule reading files through its context: from the pull request's head
/// or its merge base, as git shows them, whatever commit the run built.
@Suite("Reading files through a run's context")
struct ContextFilesTests {
    @Test("a run's context reads every changed file at the head and the merge base as git show prints it")
    func actions() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let context = try await Context.actions(environment: fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        ))
        let oracle = GitOracle(directory: fixture.repository.path)
        let git = context.git
        let paths = git.createdFiles + git.modifiedFiles + git.deletedFiles + git.renamedFiles.map(\.from)
        #expect(paths.count >= 8)
        try await [(Context.Side.head, git.head), (.mergeBase, git.mergeBase)].asyncForEach { side, commit in
            try await paths.asyncForEach { path in
                let shown = try oracle.show(path, at: commit)
                let read = try await context.contents(ofFileAt: path, at: side)
                #expect(read == shown.map(FileContents.bytes) ?? .noSuchFile, "\(path) at \(side)")
            }
        }
    }

    @Test("the head is the pull request's, not the merge the run built, and the merge base isn't the base's tip")
    func sides() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let context = try await Context.actions(environment: fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        ))
        let oracle = GitOracle(directory: fixture.repository.path)
        // The merge has the base's three lines on top; the head hasn't.
        let built = try #require(try oracle.show("a.swift", at: fixture.built))
        let head = try #require(try oracle.show("a.swift", at: fixture.head))
        #expect(built != head)
        #expect(try await context.contents(ofFileAt: "a.swift") == .bytes(head))
        #expect(try await context.contents(ofFileAt: "a.swift", at: .head) == .bytes(head))

        #expect(try await context.contents(ofFileAt: "gone.swift") == .noSuchFile)
        #expect(try await context.contents(ofFileAt: "gone.swift", at: .mergeBase) == .bytes(Array("gone\n".utf8)))
        #expect(try await context.contents(ofFileAt: PullRequestFixture.quotedPath) == .bytes(Array("new\n".utf8)))
        #expect(try await context.contents(ofFileAt: PullRequestFixture.quotedPath, at: .mergeBase) == .noSuchFile)
        #expect(try await context.contents(ofFileAt: "old.swift") == .noSuchFile)
        #expect(try await context.contents(ofFileAt: "new.swift")
            == context.contents(ofFileAt: "old.swift", at: .mergeBase))
        #expect(try await context.contents(ofFileAt: "image.png")
            == .bytes([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 0]))
        // The base renamed moved.swift after the fork point, the merge base.
        #expect(try await context.contents(ofFileAt: "relocated.swift", at: .mergeBase) == .noSuchFile)
        #expect(try oracle.show("relocated.swift", at: fixture.base) != nil)
    }

    @Test("a dry run's context reads its head and merge base too")
    func dryRun() async throws {
        let fixture = try DryRunTests.checkedOutFixture()
        defer { fixture.remove() }
        let context = try await DryRunTests.context(["--base", "main"], in: fixture)
        let oracle = GitOracle(directory: fixture.repository.path)
        #expect(context.git.head == fixture.head)
        try await ["a.swift", "gone.swift", "new.swift", "old.swift"].asyncForEach { path in
            let head = try oracle.show(path, at: context.git.head)
            let mergeBase = try oracle.show(path, at: context.git.mergeBase)
            #expect(try await context.contents(ofFileAt: path) == head.map(FileContents.bytes) ?? .noSuchFile)
            #expect(try await context.contents(ofFileAt: path, at: .mergeBase)
                == mergeBase.map(FileContents.bytes) ?? .noSuchFile)
        }
    }

    @Test("by default a file of exactly 1 MiB is read and one byte more is reported; a rule may raise the limit")
    func defaultLimit() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let limit = FileContents.defaultLimit
        #expect(limit == 1 << 20)
        let exact = (0..<limit).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        try repository.write(Data(exact), to: "exact.bin")
        try repository.write(Data(exact + [1]), to: "over.bin")
        let commit = try repository.commit("Big files", at: PullRequestFixture.time)
        var context = Context.stub()
        context.git = GitChanges(diff: Diff(diff: ""), commits: [], mergeBase: commit, head: commit)
        context.localRepository = GitRepository(git: Git(directory: repository.path))

        #expect(try await context.contents(ofFileAt: "exact.bin") == .bytes(exact))
        #expect(try await context.contents(ofFileAt: "over.bin") == .tooLarge(size: limit + 1))
        #expect(try await context.contents(ofFileAt: "over.bin", limit: limit + 1) == .bytes(exact + [1]))
        #expect(try await context.contents(ofFileAt: "exact.bin", at: .mergeBase, limit: 10) == .tooLarge(size: limit))
    }

    @Test("a context hands its reader the side's commit, the path, and the limit, and passes on its errors")
    func reader() async throws {
        var context = Context.stub()
        context.localRepository = EchoingFiles()
        #expect(try await context.contents(ofFileAt: "a b.swift")
            == .bytes(Array("a b.swift \(Context.stubHead) \(1 << 20)".utf8)))
        #expect(try await context.contents(ofFileAt: "a.swift", at: .mergeBase, limit: 5)
            == .bytes(Array("a.swift \(Context.stubBase) 5".utf8)))
        context.localRepository = FailingFiles()
        await #expect(throws: FailingFiles.Failure.self) {
            try await context.contents(ofFileAt: "a.swift")
        }
    }

    @Test("contexts that differ only in their reader are equal")
    func equality() {
        var echoing = Context.stub()
        echoing.localRepository = EchoingFiles()
        #expect(echoing == Context.stub())
        var other = echoing
        other.run.workspace = "/elsewhere"
        #expect(other != echoing)
    }
}

/// Reads every file as the path, commit, and limit it was asked for.
private struct EchoingFiles: LocalRepository {
    func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
        .bytes(Array("\(path) \(commit) \(limit)".utf8))
    }
}

/// Fails every read.
private struct FailingFiles: LocalRepository {
    struct Failure: Error {}

    func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
        throw Failure()
    }
}
