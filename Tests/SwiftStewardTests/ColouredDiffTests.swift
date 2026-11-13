import Foundation
import Testing

/// Coloured diffs: GitDiffKit removes git's colour codes, so the CLI reads
/// `git diff --color=always` as git's plain diff of the same commits.
@Suite("Coloured diffs")
struct ColouredDiffTests {
    @Test("steward changes reads a coloured diff as its plain twin, from a file and from standard input")
    func changes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-coloured-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Global and system configuration shut out, so a user's signing,
        // hooks, or external diff tool can't change or stop the fixture.
        func git(_ arguments: String...) throws -> Data {
            try Subprocess.output(of: ["git"] + arguments, in: directory, environment: [
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_AUTHOR_NAME": "Ada Lovelace",
                "GIT_AUTHOR_EMAIL": "ada@example.com",
                "GIT_COMMITTER_NAME": "Charles Babbage",
                "GIT_COMMITTER_EMAIL": "charles@example.com",
            ])
        }
        func write(_ text: String, to path: String) throws {
            try Data(text.utf8).write(to: directory.appendingPathComponent(path))
        }
        _ = try git("init", "--quiet")
        try write("one\ntwo\nthree\nfour\nfive\n", to: "a.swift")
        try write("gone\n", to: "b.swift")
        _ = try git("add", ".")
        _ = try git("commit", "--quiet", "-m", "base")
        try write("one\nTWO\nthree\nfive\nsix\n", to: "a.swift")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("b.swift"))
        try write("new\n", to: "c d.swift")
        _ = try git("add", "-A")
        _ = try git("commit", "--quiet", "-m", "head")

        let coloured = try git("diff", "--color=always", "HEAD~", "HEAD")
        let plain = try git("diff", "--no-color", "HEAD~", "HEAD")
        #expect(coloured.contains(0x1B))
        #expect(!plain.contains(0x1B))
        let colouredURL = directory.appendingPathComponent("coloured.diff")
        let plainURL = directory.appendingPathComponent("plain.diff")
        try coloured.write(to: colouredURL)
        try plain.write(to: plainURL)

        let expected = try CommandLineTool.run(arguments: ["changes", plainURL.path])
        let entries = try JSONDecoder().decode([ChangesEntry].self, from: expected)
        // The deleted file has no lines in the head, so it isn't listed.
        #expect(entries.map(\.path) == ["a.swift", "c d.swift"])
        #expect(entries.map(\.lineCount) == [2, 1])
        #expect(try CommandLineTool.run(arguments: ["changes", colouredURL.path]) == expected)
        #expect(try CommandLineTool.run(arguments: ["changes", "-"], standardInput: colouredURL) == expected)
    }
}
