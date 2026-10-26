import Foundation
import GitDiffKit
@testable import Steward
import Testing

/// The Actions-run suite checks every pull request's context with these
/// oracles, so one that rejects a valid pull request fails its CI.
@Suite("Valid pull requests the oracles accept")
struct OracleTests {
    private static let time = PullRequestFixture.time

    @Test("paths with tabs, leading or inside, match git in the diff and the line map")
    func tabsInPaths() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let lines = (1...10).map { "line \($0)\n" }
        // With `-z`, git writes these tabs unquoted.
        let paths = ["\tlead.swift", "mid\tdle.swift"]
        try paths.forEach { try repository.write(lines.joined(), to: $0) }
        try repository.commit("Start", at: Self.time)
        try repository.git(["switch", "--quiet", "--create", "feature"])
        try paths.forEach { path in
            try repository.write(lines.enumerated().map { $0 == 7 ? "changed\n" : $1 }.joined(), to: path)
        }
        let head = try repository.commit("Change line 8", at: Self.time + 10)
        try repository.git(["switch", "--quiet", "main"])
        try paths.forEach { try repository.write("base 1\nbase 2\n\(lines.joined())", to: $0) }
        let base = try repository.commit("Insert at the top", at: Self.time + 20)
        try repository.git(["switch", "--quiet", "--create", "merge"])
        let built = try repository.merge("feature", at: Self.time + 30)

        let context = try await Context.actions(
            environment: repository.actionsEnvironment(base: base, head: head, built: built)
        )
        #expect(context.git.modifiedFiles == paths)
        #expect(context.run.lineMap.headLocation(ofLine: 10, inFile: paths[1]) == Location(path: paths[1], line: 8))
        let oracle = GitOracle(directory: repository.path)
        try oracle.verify(context.git, base: base)
        try oracle.verify(context.run.lineMap, head: head, built: built)
    }

    @Test("a commit in another encoding reads in UTF-8, as git log gives it")
    func encodedCommit() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        try repository.write("one\n", to: "a.swift")
        let base = try repository.commit("Start", at: Self.time)
        try repository.write("two\n", to: "a.swift")
        // "Café" and "Naïve." in ISO-8859-1, bytes no Swift string holds.
        let head = try Self.commit(
            Array("Caf".utf8) + [0xE9] + Array("\n\nNa".utf8) + [0xEF] + Array("ve.\n".utf8),
            in: repository,
            with: ["-c", "i18n.commitEncoding=ISO-8859-1", "commit"]
        )

        let context = try await Context.actions(environment: repository.actionsEnvironment(base: base, head: head))
        #expect(context.git.commits.map(\.subject) == ["Café"])
        #expect(context.git.commits.map(\.body) == ["Naïve."])
        try GitOracle(directory: repository.path).verify(context.git, base: base)
    }

    @Test("a message with lines of whitespace only reads as git's subject and body")
    func whitespaceParagraphs() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        try repository.write("one\n", to: "a.swift")
        let base = try repository.commit("Start", at: Self.time)
        try repository.write("two\n", to: "a.swift")
        // Verbatim: git's default cleanup would empty those lines.
        let head = try Self.commit(
            Array("Subject one  \nsubject two\t\n \t\r\n\nBody line\n\n".utf8),
            in: repository,
            with: ["commit", "--cleanup=verbatim"]
        )

        let context = try await Context.actions(environment: repository.actionsEnvironment(base: base, head: head))
        #expect(context.git.commits.map(\.subject) == ["Subject one subject two"])
        #expect(context.git.commits.map(\.body) == ["Body line"])
        try GitOracle(directory: repository.path).verify(context.git, base: base)
    }

    @Test("submodules on either side need no commits of their own, in the diff or the line map")
    func gitlinks() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        try repository.write("one\n", to: "a.swift")
        try repository.commit("Start", at: Self.time)
        try repository.git(["switch", "--quiet", "--create", "feature"])
        try Self.addGitlink("tools", in: repository)
        let head = try repository.commitIndex("Add a submodule", at: Self.time + 10)
        try repository.git(["switch", "--quiet", "main"])
        try Self.addGitlink("vendor", in: repository)
        let base = try repository.commitIndex("Add another", at: Self.time + 20)
        try repository.git(["switch", "--quiet", "--create", "merge"])
        let built = try repository.merge("feature", at: Self.time + 30)

        let context = try await Context.actions(
            environment: repository.actionsEnvironment(base: base, head: head, built: built)
        )
        #expect(context.git.createdFiles == ["tools"])
        let oracle = GitOracle(directory: repository.path)
        try oracle.verify(context.git, base: base)
        try oracle.verify(context.run.lineMap, head: head, built: built)
    }

    @Test("a text file a -diff attribute marks binary maps no lines")
    func binaryByAttribute() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let lines = (1...5).map { "line \($0)\n" }.joined()
        try repository.write("*.dat -diff\n", to: ".gitattributes")
        try repository.write(lines, to: "data.dat")
        try repository.write("one\n", to: "a.swift")
        try repository.commit("Start", at: Self.time)
        try repository.git(["switch", "--quiet", "--create", "feature"])
        try repository.write("two\n", to: "a.swift")
        let head = try repository.commit("Change the code", at: Self.time + 10)
        try repository.git(["switch", "--quiet", "main"])
        try repository.write("base\n\(lines)", to: "data.dat")
        let base = try repository.commit("Change the data", at: Self.time + 20)
        try repository.git(["switch", "--quiet", "--create", "merge"])
        let built = try repository.merge("feature", at: Self.time + 30)

        let context = try await Context.actions(
            environment: repository.actionsEnvironment(base: base, head: head, built: built)
        )
        #expect(context.run.lineMap.headLocation(ofLine: 2, inFile: "data.dat") == nil)
        let oracle = GitOracle(directory: repository.path)
        try oracle.verify(context.git, base: base)
        try oracle.verify(context.run.lineMap, head: head, built: built)
    }

    @Test("a type change counts as one changed file, as GitHub counts it")
    func typeChangeCounts() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        try repository.write("target\n", to: "target.swift")
        try repository.write("one\n", to: "file.swift")
        let base = try repository.commit("Start", at: Self.time)
        try FileManager.default.removeItem(at: repository.url.appendingPathComponent("file.swift"))
        try FileManager.default.createSymbolicLink(
            at: repository.url.appendingPathComponent("file.swift"),
            withDestinationURL: URL(fileURLWithPath: "target.swift")
        )
        let head = try repository.commit("Link the file", at: Self.time + 10)
        let environment = try repository.actionsEnvironment(base: base, head: head)
        // What GitHub says of it: the file's line deleted, the link's target
        // added, and one file changed (fastlane/fastlane#7479).
        try EventPayload.recorded("pull-request-event.opened")
            .setting(base: base, head: head, fields: ["changed_files": 1, "additions": 1, "deletions": 1, "commits": 1])
            .write(to: repository.eventURL)

        let context = try await Context.actions(environment: environment)
        #expect(context.git.diff.files.count == 2)
        context.expectCountsMatchGitHub()
    }

    /// Commits the working tree with `message` exactly as its bytes are,
    /// running git with `arguments`, which hold `commit`, and returns the
    /// commit's SHA.
    private static func commit(
        _ message: [UInt8],
        in repository: TestRepository,
        with arguments: [String]
    ) throws -> String {
        try repository.git(["add", "--all"])
        let file = repository.root.appendingPathComponent("message")
        try Data(message).write(to: file)
        let date = "@\(time + 10) +0000"
        try repository.git(
            arguments + ["--quiet", "--no-verify", "--file", file.path],
            environment: ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]
        )
        return try repository.git(["rev-parse", "HEAD"])
    }

    /// Stages a submodule at `path` whose commit this repository lacks, as a
    /// submodule's usually is. Its directory stays empty, as an unpopulated
    /// submodule's does, so adding the working tree keeps it.
    private static func addGitlink(_ path: String, in repository: TestRepository) throws {
        try FileManager.default.createDirectory(
            at: repository.url.appendingPathComponent(path),
            withIntermediateDirectories: true
        )
        let commit = String(repeating: "ab", count: 20)
        try repository.git(["update-index", "--add", "--cacheinfo", "160000,\(commit),\(path)"])
    }
}
