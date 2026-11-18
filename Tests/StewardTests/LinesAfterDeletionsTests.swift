import Foundation
import GitDiffKit
@testable import Steward
import StewardTesting
import Testing

/// `GitChanges.linesAfterDeletions` and `ChangedFile.linesAfterDeletions`:
/// the head line that stands where each run of deleted lines was.
@Suite("Lines after deletions")
struct LinesAfterDeletionsTests {
    /// A change to `A.swift`, as one hunk or more.
    enum Change: String, CaseIterable {
        case inside, rewrite, atTheEnd, emptied, twoRuns, beforeNoNewline
        case pureDeletionWithoutContext, rewriteWithoutContext, atTheStartWithoutContext, twoHunksWithoutContext

        /// The hunks, after the file's header.
        var hunks: String {
            switch self {
            case .inside: "@@ -1,4 +1,3 @@\n a\n-b\n c\n d\n"
            case .rewrite: "@@ -1,3 +1,4 @@\n a\n-b\n+x\n+y\n c\n"
            case .atTheEnd: "@@ -1,3 +1 @@\n a\n-b\n-c\n"
            case .emptied: "@@ -1,2 +0,0 @@\n-a\n-b\n"
            case .twoRuns: "@@ -1,5 +1,3 @@\n a\n-b\n c\n-d\n e\n"
            case .beforeNoNewline:
                "@@ -1,2 +1 @@\n-a\n-b\n\\ No newline at end of file\n+a\n\\ No newline at end of file\n"
            case .pureDeletionWithoutContext: "@@ -5 +4,0 @@\n-e\n"
            case .rewriteWithoutContext: "@@ -5 +5,2 @@\n-e\n+x\n+y\n"
            case .atTheStartWithoutContext: "@@ -1,2 +0,0 @@\n-a\n-b\n"
            case .twoHunksWithoutContext: "@@ -2 +1,0 @@\n-b\n@@ -4 +2,0 @@\n-d\n"
            }
        }

        /// The head lines after the deletions: the context line after a
        /// run, a rewrite's first line, or one past the file's last line.
        var expected: [Int] {
            switch self {
            case .inside, .rewrite, .atTheEnd: [2]
            case .emptied, .beforeNoNewline, .atTheStartWithoutContext: [1]
            case .pureDeletionWithoutContext, .rewriteWithoutContext: [5]
            case .twoRuns, .twoHunksWithoutContext: [2, 3]
            }
        }
    }

    @Test("a run of deleted lines gives the head line that now stands where it was", arguments: Change.allCases)
    func runs(change: Change) throws {
        let git = try Context.fixture(diff: """
            diff --git a/A.swift b/A.swift
            index 1111111..2222222 100644
            --- a/A.swift
            +++ b/A.swift
            \(change.hunks)
            """).git
        #expect(git.linesAfterDeletions.files["A.swift"]?.allLines == change.expected)
        #expect(git.linesAfterDeletions(in: "A.swift").allLines == change.expected)
        #expect(git.linesAfterDeletions(in: "B.swift").isEmpty)
    }

    @Test("a created, deleted or only renamed file gives no line, and changedLines doesn't count a deletion")
    func noLines() throws {
        let git = try Context.fixture(diff: """
            diff --git a/New.swift b/New.swift
            new file mode 100644
            index 0000000..1111111
            --- /dev/null
            +++ b/New.swift
            @@ -0,0 +1 @@
            +a
            diff --git a/Gone.swift b/Gone.swift
            deleted file mode 100644
            index 2222222..0000000
            --- a/Gone.swift
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -a
            -b
            diff --git a/Old.swift b/Moved.swift
            similarity index 100%
            rename from Old.swift
            rename to Moved.swift
            diff --git a/A.swift b/A.swift
            index 3333333..4444444 100644
            --- a/A.swift
            +++ b/A.swift
            @@ -1,3 +1,2 @@
             a
            -b
             c

            """).git
        #expect(git.linesAfterDeletions == ChangedLines(files: ["A.swift": LineRangeSet([2...2])]))
        #expect(git.linesAfterDeletions(in: "Gone.swift").isEmpty)
        #expect(git.changedLines == ChangedLines(files: ["New.swift": LineRangeSet([1...1])]))
    }

    /// `A.swift` at the base: three functions, the second with an
    /// attribute above it and a comment below it.
    static let functions = """
        func double(_ x: Int) -> Int {
            print("doubling")
            return x * 2
        }

        @inlinable
        func half(_ x: Int) -> Int {
            x / 2
        }
        // The end of half.

        func triple(_ x: Int) -> Int {
            x * 3
        }

        """

    @Test("a rule sees a function that lost a line or its attribute as changed, and not one with a deletion below")
    func functionThatLostALine() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        try repository.write(Self.functions, to: "A.swift")
        let base = try repository.commit("Functions", at: 0)
        // Deletes `print`, `@inlinable` and the comment below `half`.
        let deleted = ["    print(\"doubling\")", "@inlinable", "// The end of half."]
        let head = Self.functions.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !deleted.contains(String($0)) }
            .joined(separator: "\n")
        try repository.write(head, to: "A.swift")
        let headCommit = try repository.commit("Deletions", at: 1)

        let git = Git(directory: repository.path, environment: TestRepository.runEnvironment(adding: [:]))
        var context = try Context.fixture(diff: "")
        context.git = try await GitChanges(base: base, head: headCommit, git: git)
        context.localRepository = GitRepository(git: git)
        let rule = Rule.changedFiles("Functions", in: "**/*.swift") { file in
            Self.functionSpans(in: file.contents).compactMap { name, lines in
                file.changedLines.overlaps(lines) || file.linesAfterDeletions.overlaps(lines)
                    ? .message("Changes `\(name)`", at: Location(path: file.path, line: lines.lowerBound)) : nil
            } + [.markdown("changed: \(file.changedLines.allLines), after: \(file.linesAfterDeletions.allLines)")]
        }
        let findings = try await rule.evaluate(context)
        #expect(findings == [
            .message("Changes `double`", at: Location(path: "A.swift", line: 1)),
            .message("Changes `half`", at: Location(path: "A.swift", line: 5)),
            .markdown("changed: [], after: [2, 5, 8]"),
        ])
        let after = ChangedLines(files: ["A.swift": LineRangeSet([2...2, 5...5, 8...8])])
        #expect(context.git.linesAfterDeletions == after)
        #expect(context.git.changedLines.files.isEmpty)
    }

    /// Each function in `contents` by name, from its `func` line to the
    /// next line that is a lone `}`.
    static func functionSpans(in contents: [UInt8]) -> [(name: String, lines: ClosedRange<Int>)] {
        let lines = String(decoding: contents, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.indices.compactMap { index in
            guard lines[index].hasPrefix("func "),
                  let end = lines[index...].firstIndex(of: "}")
            else { return nil }
            let name = lines[index].dropFirst(5).prefix { $0 != "(" }
            return (String(name), (index + 1)...(end + 1))
        }
    }
}
