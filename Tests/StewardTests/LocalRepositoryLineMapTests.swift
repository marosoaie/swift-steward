import Foundation
@testable import Steward
import Testing

/// `LocalRepository.commit(named:)` and `lineMap(from:to:attributesFrom:)`:
/// the git reader's, as a run's line map reads, and the protocol's
/// defaults.
@Suite("The reader's commits and line maps")
struct LocalRepositoryLineMapTests {
    @Test("the git reader names commits as git does and reads the run's own line map, through the protocol")
    func gitReader() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let context = try await Context.actions(environment: fixture.repository.actionsEnvironment(
            base: fixture.base,
            head: fixture.head,
            built: fixture.built
        ))
        let files: any LocalRepository = context.localRepository
        #expect(try await files.commit(named: fixture.built) == fixture.built)
        #expect(try await files.commit(named: String(fixture.head.prefix(10))) == fixture.head)
        #expect(try await files.commit(named: "HEAD") == fixture.repository.git(["rev-parse", "HEAD"]))
        #expect(try await files.commit(named: "no-such-branch") == nil)
        // A name is never an option: git reads it as a commit's.
        #expect(try await files.commit(named: "--all") == nil)
        // Nor a range's end: git verifies `^HEAD`, and prints `^<sha>`.
        #expect(try await files.commit(named: "^HEAD") == nil)

        let map = try await files.lineMap(from: fixture.built, to: fixture.head, attributesFrom: fixture.forkPoint)
        #expect(map == context.run.lineMap)
        #expect(map != .identity)
        #expect(try await files.lineMap(from: fixture.head, to: fixture.head, attributesFrom: fixture.forkPoint)
            == .identity)
        // The base renamed moved.swift, so the map reads renames.
        #expect(map.headPath(ofFile: "relocated.swift") == "moved.swift")
        // What a test gives the fake: git's own diff, with context lines or
        // without, read by `LineMap(diff:)`; the other way round, it maps
        // another way.
        let diff = { (options: [String]) in try fixture.repository.git(["diff", "-M"] + options) + "\n" }
        #expect(try LineMap(diff: diff(["--unified=0", fixture.head, fixture.built])) == map)
        #expect(try LineMap(diff: diff([fixture.head, fixture.built])) == map)
        #expect(try LineMap(diff: diff([fixture.built, fixture.head])) != map)
    }

    @Test("a reader that gives only reads knows no commit, and maps a commit only to itself")
    func defaults() async throws {
        let files: any LocalRepository = NoLocalRepository()
        #expect(try await files.commit(named: "HEAD") == nil)
        #expect(try await files.lineMap(from: "a", to: "a", attributesFrom: "b") == .identity)
        await #expect(throws: MissingLineMap.self) {
            try await files.lineMap(from: "a", to: "b", attributesFrom: "c")
        }
    }
}
