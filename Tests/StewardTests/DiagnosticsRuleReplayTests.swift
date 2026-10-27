import Foundation
@testable import Steward
import Testing

/// docs/danger.md's shifted case (section 2, and Checks), replayed: had
/// git-diff-parser#2 landed before #1, CI would have built a merge tree in
/// which #1's added line `**Doc comments on public API; …**` is line 96 of
/// `AGENTS.md`, where the pull request shows it as line 91.
///
/// Uses the git-diff-parser mirror `RealPullRequestTests` clones; set
/// `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS` to skip.
@Suite(
    "The diagnostics rule on git-diff-parser#1 replayed onto #2",
    .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
)
struct DiagnosticsRuleReplayTests {
    /// #2's head, which stands in for the base.
    private static let base = "ce6e916eccff315f73daff1a9b3025e250d3ab24"
    /// #1's head.
    private static let head = "b81007f5d6c7bef0258e2a1192617b5990193620"
    private static let line = "**Doc comments on public API; elsewhere only where names fall short.**"

    @Test("a linter's line 96 of the merge tree is a finding at line 91, the pull request's")
    func shiftedLine() async throws {
        let mirror = try RepositoryMirror.local("git-diff-parser", having: [Self.base, Self.head])
        let clone = try TestRepository(cloning: mirror.path, options: ["--shared", "--no-checkout"])
        defer { clone.remove() }
        let tree = try clone.git(["merge-tree", "--write-tree", Self.base, Self.head])
        let built = try clone.git(["commit-tree", tree, "-p", Self.base, "-p", Self.head, "-m", "Merge #1 into #2"])
        try clone.git(["switch", "--quiet", "--detach", built])
        let builtLine = try Self.number(of: Self.line, in: "AGENTS.md", at: built, in: clone)
        #expect(builtLine == 96)
        #expect(try Self.number(of: Self.line, in: "AGENTS.md", at: Self.head, in: clone) == 91)

        try clone.write("\(clone.path)/AGENTS.md:\(builtLine):1: warning: Line is long (MD013)\n", to: "lint.log")
        let context = try await Context.actions(environment: clone.actionsEnvironment(
            base: Self.base,
            head: Self.head,
            built: built
        ))
        let rule = Rule.diagnosticsOnChangedLines(in: [.swiftLint("lint.log")])
        #expect(try await rule.evaluate(context) == [
            .warning("Line is long (`MD013`)", at: Location(path: "AGENTS.md", line: 91)),
        ])
    }

    /// The 1-based number of the first line of `path` at `commit` that is
    /// `text`.
    private static func number(
        of text: String,
        in path: String,
        at commit: String,
        in repository: TestRepository
    ) throws -> Int {
        let contents = String(decoding: try repository.gitBytes(["show", "\(commit):\(path)"]), as: UTF8.self)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        return try #require(lines.firstIndex { $0 == text }) + 1
    }
}
