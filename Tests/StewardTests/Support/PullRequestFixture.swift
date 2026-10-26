import Foundation

/// A test repository holding a pull request whose base moved after the
/// branch was cut, and the merge commit Actions would build.
///
/// From the fork point, the pull request (two commits) edits `a.swift` and
/// `moved.swift`, renames `old.swift`, deletes `gone.swift`, adds a binary
/// file and a file whose path needs quoting, and makes `run.sh`
/// executable. Meanwhile the base inserts three lines at the top of
/// `a.swift`, and renames `moved.swift` to `relocated.swift` with two lines
/// inserted at its top, so the merge shifts lines and paths.
struct PullRequestFixture {
    let repository: TestRepository
    let forkPoint: String
    /// The base branch's tip, the event's `base.sha`.
    let base: String
    /// The pull request's commits, oldest first; the last is the head.
    let commits: [String]
    /// The merge of the head into the base: `GITHUB_SHA`.
    let built: String

    var head: String { commits[commits.count - 1] }

    static let time = 1_700_000_000

    static let quotedPath = "dir with space/\u{DC}n\u{EF}c\u{F6}d\u{E9}.swift"

    init() throws {
        let repository = try TestRepository()
        self.repository = repository
        let lines = (1...20).map { "line \($0)" }
        let moved = (1...10).map { "moved \($0)" }
        try repository.write(Self.text(lines), to: "a.swift")
        try repository.write(Self.text(moved), to: "moved.swift")
        try repository.write(Self.text((1...5).map { "old \($0)" }), to: "old.swift")
        try repository.write("gone\n", to: "gone.swift")
        try repository.write("echo run\n", to: "run.sh")
        forkPoint = try repository.commit("Start", at: Self.time)

        try repository.git(["switch", "--quiet", "--create", "feature"])
        try repository.write(Self.text(Self.replacing(10, in: lines)), to: "a.swift")
        try repository.write(Self.text(Self.replacing(5, in: moved)), to: "moved.swift")
        try repository.git(["mv", "old.swift", "new.swift"])
        try repository.git(["rm", "--quiet", "gone.swift"])
        try repository.write("new\n", to: Self.quotedPath)
        try repository.write(Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 0]), to: "image.png")
        let first = try repository.commit("Change files\n\nWith a body\nover two lines.\n", at: Self.time + 100)
        try repository.write(Self.text(Self.replacing(15, in: Self.replacing(10, in: lines))), to: "a.swift")
        // On disk, not with `update-index --chmod`: committing adds the
        // working tree again.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: repository.url.appendingPathComponent("run.sh").path
        )
        let second = try repository.commit("Make run.sh executable", at: Self.time + 200)
        commits = [first, second]

        try repository.git(["switch", "--quiet", "main"])
        try repository.write(Self.text(["base 1", "base 2", "base 3"] + lines), to: "a.swift")
        try repository.git(["mv", "moved.swift", "relocated.swift"])
        try repository.write(Self.text(["base 1", "base 2"] + moved), to: "relocated.swift")
        base = try repository.commit("Move the base", at: Self.time + 150)

        try repository.git(["switch", "--quiet", "--create", "merge"])
        built = try repository.merge("feature", at: Self.time + 300)
    }

    func remove() {
        repository.remove()
    }

    private static func text(_ lines: [String]) -> String {
        lines.map { "\($0)\n" }.joined()
    }

    private static func replacing(_ line: Int, in lines: [String]) -> [String] {
        lines.enumerated().map { index, text in index + 1 == line ? "changed \(line)" : text }
    }
}
