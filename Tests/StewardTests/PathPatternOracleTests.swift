import Foundation
import GitDiffKit
@testable import Steward
import Testing

@Suite("Path patterns match what git's :(glob) pathspecs match")
struct PathPatternOracleTests {
    /// Paths that tell the patterns apart: nested and top-level files,
    /// file and directory names that differ only in case or contain a
    /// pattern's special characters, a multibyte character, and names that
    /// aren't UTF-8.
    private static let paths: [[UInt8]] = [
        "top.swift", "a.txt", "README.md", "x.swift.orig", "ab", "a b/c", "*star",
        "Sources.swift", "Sources/A.swift", "Sources/Sub/B.swift", "Sources/Sub/Deep/C.swift", "SourcesX/y.swift",
        "mbk/u.txt", "mbk/é.txt", "mbk/[x].txt", "mbk/a.txt", "mbk/*", "mbk/a\\.txt", "mbk/docs/r.md",
        "mbk/i.png", "mbk/sub/x/y.txt", "MBK/up.txt",
        "a/b", "a/x/b", "a/x/y/b", "mb?/f", "mb*/g", "mb\\k/h", "docs/guide.md", "lib/docs/notes.md",
        "dir/*/x", "dir/\\*/y", "dir/[g]/w", "dir/sub/z",
    ].map { Array($0.utf8) } + [
        Array("mbk/".utf8) + [0xFF] + Array(".txt".utf8),
        [0xFE] + Array("/z.swift".utf8),
    ]

    private static let patterns: [PathPattern] = [
        "**", "***", "**/*", "**/**", "*", "?", "??", "*/b",
        "mbk", "mbk/", "mbk/**", "mbk/***", "MBK/**", "mbk/**/**",
        "Sources", "Sources/", "Sources/*", "Sources/**", "Sources/*/*.swift", "Sources/Sub", "Sources/Sub/",
        "Sources/**/C.swift", "Sources/**/*.swift", "SourcesX", "Source?", "Source?/**",
        "*.swift", "**/*.swift", "x.swift*", "*.orig", "**/*.orig", "**/y.swift", "**/z.swift", "*/z.swift",
        "mbk/?.txt", "mbk/??.txt", "mbk/*.txt", "mbk/é.txt",
        "mbk/\\[x].txt", "mbk/\\[x\\].txt", "mbk/a\\.txt", "mbk/\\*", "mbk/a\\\\*",
        "mbk/docs/**", "**/r.md", "mbk/**/r.md", "mbk/**/i.png", "mbk/**/**/r.md",
        "**/docs", "**/docs/**", "mbk/d*s",
        "mb?", "mb?/**", "mb*/**", "mb?/f", "mb\\?/f", "mb*/g", "mb\\k", "mb\\\\k",
        "a", "a/", "a/**/b", "**/b", "a/*/b", "a b/*", "\\**", "*star", "\\*star", "\\/mbk",
        "*/**", "*/*", "?/**", "**/*/**", "a/**/**", "mbk/*/**", "mbk/*/*", "**/a/**", "**/x/**", "Sources/**/**",
        "dir/sub/", "dir/*/**", "dir/\\*/**", "dir/\\[g\\]/**", "dir/\\*", "dir/\\[g\\]", "dir/\\sub/**",
        "mb\\k/**", "mb\\\\k/**", "mb*\\/**", "Sources/*/**",
        "**/Sub/**/*.swift", "**/*.txt", "\\a.txt", "mbk/\\é.txt", "*.md", "docs", "**/docs/*.md",
    ]

    @Test("every pattern matches exactly the paths git ls-files lists for it")
    func patternsMatchWhatGitMatches() throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        try repository.git(["config", "core.ignorecase", "false"])
        let blob = try repository.git(["hash-object", "-w", "--stdin"])
        // Through the index alone, so names that aren't UTF-8 or differ
        // only in case need no files on disk.
        let entries: [UInt8] = Self.paths.flatMap { Array("100644 \(blob)\t".utf8) + $0 + [0] }
        let entriesURL = repository.root.appendingPathComponent("index-info")
        try Data(entries).write(to: entriesURL)
        _ = try Subprocess.output(
            of: ["sh", "-c", "git update-index -z --index-info < \"$0\"", entriesURL.path],
            in: repository.url,
            environment: TestRepository.environment
        )

        try Self.patterns.forEach { pattern in
            let listed = try repository.gitBytes(["ls-files", "-z", "--", ":(glob)\(pattern)"])
                .split(separator: 0, omittingEmptySubsequences: true)
                .map { Array($0) }
            let matcher = try PathMatcher(pattern)
            let matched = Self.paths.filter { matcher.matches(DiffPath($0)) }
            #expect(Set(matched) == Set(listed), "\(pattern)")
        }
    }

    @Test(
        "a malformed pattern throws an error that names it",
        arguments: [
            ("", PathPatternError.Kind.empty),
            ("/mbk/**", .leadingSlash),
            ("/", .leadingSlash),
            ("mbk//i.png", .invalidComponent("")),
            ("mbk///", .invalidComponent("")),
            ("./mbk", .invalidComponent(".")),
            ("mbk/./i.png", .invalidComponent(".")),
            ("mbk/../top.swift", .invalidComponent("..")),
            ("mbk/..", .invalidComponent("..")),
            ("mbk/[x", .unescapedBracket),
            ("mbk/[x].txt", .unescapedBracket),
            ("mbk/a.tx[", .unescapedBracket),
            ("[ab]", .unescapedBracket),
            ("mbk/[x]/", .unescapedBracket),
            ("mbk\\", .trailingBackslash),
            ("mbk/\\\\\\", .trailingBackslash),
            ("Sources**", .partialGlobstar),
            ("a**b", .partialGlobstar),
            ("mbk/**x", .partialGlobstar),
            ("**.swift", .partialGlobstar),
            ("**\\/b", .partialGlobstar),
            ("\\***", .partialGlobstar),
            ("Sources**/", .partialGlobstar),
        ]
    )
    func malformedPatternThrows(pattern: String, kind: PathPatternError.Kind) {
        let error = PathPatternError(pattern: PathPattern(pattern), kind: kind)
        #expect(throws: error) { try PathMatcher(PathPattern(pattern)) }
        #expect(pattern.isEmpty || error.description.contains("“\(pattern)”"))
    }

    /// Git matches a pattern that ends in `/` only as written: `dir/*/`
    /// matches `dir/*/x` alone, and `dir/\*/` matches `dir/\*/y`, while
    /// `dir/\*/**` matches `dir/*/x`. The oracle test pins the `**` forms.
    @Test(
        "a pattern that ends in / and has a wildcard or an escape throws, and suggests its ** form, which is accepted",
        arguments: [
            "*/", "**/", "mbk/**/", "**/docs/", "Sources/**/", "Sources/*/", "mb?/", "mb*/",
            "mb\\k/", "mb\\\\k/", "dir/*/", "dir/\\*/", "dir/\\[g\\]/", "dir/\\sub/", "mb*\\/",
        ]
    )
    func nonliteralDirectoryThrows(pattern: String) throws {
        let error = PathPatternError(pattern: PathPattern(pattern), kind: .nonliteralDirectory)
        #expect(throws: error) { try PathMatcher(PathPattern(pattern)) }
        #expect(error.description.contains("“\(pattern)”"))
        #expect(error.description.contains("write \(pattern)** "))
        _ = try PathMatcher(PathPattern(pattern + "**"))
    }

    @Test(
        "matching takes steps in proportion to the pattern times the path, never backtracking",
        .timeLimit(.minutes(1)),
        arguments: [
            (String(repeating: "*a", count: 30) + "b", String(repeating: "a", count: 5_000)),
            (String(repeating: "**/a/", count: 15) + "b", String(repeating: "a/", count: 2_000) + "c"),
            (String(repeating: "**/", count: 500) + "b", String(repeating: "a/", count: 1_000) + "c"),
        ]
    )
    func matchingDoesNotBacktrack(pattern: String, path: String) throws {
        let matcher = try PathMatcher(PathPattern(pattern))
        let clock = ContinuousClock()
        let elapsed = clock.measure { #expect(!matcher.matches(DiffPath(Array(path.utf8)))) }
        #expect(elapsed < .seconds(10))
    }
}
