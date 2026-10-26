import Foundation
import GitDiffKit
@testable import Steward
import Testing

@Suite("A user's git configuration can't change the context")
struct HostileConfigurationTests {
    /// Settings that change the shape of `git diff` or `git log` output when
    /// Steward doesn't pin them, each with a value that would break parsing
    /// or change what it reads.
    static let settings = [
        ("diff.noprefix", "true"),
        ("diff.mnemonicPrefix", "true"),
        ("diff.relative", "true"),
        ("diff.renames", "copies"),
        ("diff.submodule", "log"),
        ("diff.context", "10"),
        ("diff.interHunkContext", "20"),
        ("diff.external", "echo external diff"),
        ("diff.suppressBlankEmpty", "true"),
        ("color.ui", "always"),
        ("color.diff", "always"),
        ("core.quotePath", "false"),
        ("core.pager", "cat -n"),
        ("log.showSignature", "true"),
        ("log.decorate", "full"),
        ("format.pretty", "oneline"),
        ("i18n.logOutputEncoding", "ISO-8859-1"),
        ("diff.wsErrorHighlight", "all"),
        ("diff.algorithm", "patience"),
        ("diff.indentHeuristic", "false"),
        ("diff.orderFile", "order.txt"),
    ]

    @Test("the context with every hostile setting is the context without them")
    func hostileSettings() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        let repository = fixture.repository
        // A submodule entry, and a blank line next to a change: what
        // `diff.submodule` and `diff.suppressBlankEmpty` act on.
        try repository.git(["switch", "--quiet", "feature"])
        try repository.write("one\n\nthree\n", to: "blank.txt")
        try repository.commit("Add blank lines", at: PullRequestFixture.time + 240)
        try repository.write("one\n\nfour\n", to: "blank.txt")
        try repository.write("*.swift\n", to: "order.txt")
        try repository.git(["add", "blank.txt", "order.txt"])
        // Only in the index: adding the working tree would remove it.
        try repository.git(["update-index", "--add", "--cacheinfo", "160000,\(fixture.forkPoint),vendor/library"])
        let head = try repository.commitIndex("Add a submodule and blank lines", at: PullRequestFixture.time + 250)
        let environment = try repository.actionsEnvironment(base: fixture.base, head: head, built: fixture.built)

        let plain = try await Context.actions(environment: environment)
        // Before the settings, which the oracle's own git would read.
        try GitOracle(directory: repository.path).verify(plain.git, base: fixture.base)
        try Self.settings.forEach { key, value in try repository.git(["config", key, value]) }
        let hostile = try await Context.actions(environment: environment)

        #expect(hostile.git == plain.git)
        #expect(hostile.run.lineMap == plain.run.lineMap)
        #expect(hostile.git.diff.damage.isEmpty)
        #expect(hostile.git.createdFiles.contains("vendor/library"))
        #expect(hostile.git.commits.last?.subject == "Add a submodule and blank lines")
    }

    @Test("diff.interHunkContext can't merge the line map's hunks, so lines between them still map")
    func interHunkContext() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let lines = (1...10).map { "line \($0)\n" }
        try repository.write(lines.joined(), to: "a.swift")
        let head = try repository.commit("Start", at: PullRequestFixture.time)
        var changed = lines
        changed[1] = "changed 2\n"
        changed[5] = "changed 6\n"
        try repository.write(changed.joined(), to: "a.swift")
        let built = try repository.commit("Change two lines", at: PullRequestFixture.time + 1)
        try repository.git(["config", "diff.interHunkContext", "10"])

        let map = try await LineMap(built: built, head: head, git: Git(directory: repository.path))
        #expect((1...7).map { map.headLocation(ofLine: $0, inFile: "a.swift")?.line } == [1, nil, 3, 4, 5, nil, 7])
    }
}
