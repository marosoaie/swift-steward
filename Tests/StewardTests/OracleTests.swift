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
        try repository.git(["add", "--all"])
        // "Café" and "Naïve." in ISO-8859-1, bytes no Swift string holds.
        let message = repository.root.appendingPathComponent("message")
        try Data(Array("Caf".utf8) + [0xE9] + Array("\n\nNa".utf8) + [0xEF] + Array("ve.\n".utf8)).write(to: message)
        let date = "@\(Self.time + 10) +0000"
        try repository.git(
            ["-c", "i18n.commitEncoding=ISO-8859-1", "commit", "--quiet", "--no-verify", "--file", message.path],
            environment: ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]
        )
        let head = try repository.git(["rev-parse", "HEAD"])

        let context = try await Context.actions(environment: repository.actionsEnvironment(base: base, head: head))
        #expect(context.git.commits.map(\.subject) == ["Café"])
        #expect(context.git.commits.map(\.body) == ["Naïve."])
        try GitOracle(directory: repository.path).verify(context.git, base: base)
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
}
