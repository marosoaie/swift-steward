import StewardTesting
import Testing

/// A rule that asks whether the changes overlap a range of a file's lines,
/// through the public API alone, as a Dangerfile's rule would.
@Suite("A rule that asks which lines changed")
struct ChangedLineNumbersRuleTests {
    /// Warns on each changed file in which the pull request adds or
    /// rewrites a line of `lineRange`, as a rule guarding a licence header
    /// would. It reads `changedLineNumbers` once: asking
    /// `changedLineNumbers(in:)` for each file would be quadratic in the
    /// diff's files.
    static func header(_ lineRange: ClosedRange<Int>) -> Rule {
        Rule("Header") { context in
            let changed = context.git.changedLineNumbers
            return (context.git.createdFiles + context.git.modifiedFiles)
                .filter { changed.files[$0]?.overlaps(lineRange) ?? false }
                .map {
                    .warning("Changes lines \(lineRange.lowerBound)–\(lineRange.upperBound)", at: Location(path: $0))
                }
        }
    }

    @Test("a range that overlaps a file's changed lines gets that file a finding, and one that doesn't none")
    func overlaps() async throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        #expect(try await Self.header(1...2).evaluate(context).map(\.location?.path)
            == ["Sources/New.swift", "Sources/App.swift", "Sources/After.swift"])
        #expect(try await Self.header(2...2).evaluate(context).map(\.location?.path) == ["Sources/App.swift"])
        #expect(try await Self.header(3...10).evaluate(context).isEmpty)
    }

    @Test("a file's changed lines are the lines its hunks add, as merged ranges")
    func ranges() throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        #expect(context.git.changedLineNumbers(in: "Sources/App.swift").ranges == [2...2])
        #expect(context.git.changedLineNumbers(in: "Sources/After.swift").ranges == [1...1])
        #expect(context.git.changedLineNumbers(in: "Docs/Old.md").isEmpty)
        // One path's lines are those of the whole map's entry for it.
        #expect(context.git.changedLineNumbers.files.allSatisfy {
            context.git.changedLineNumbers(in: $0.key) == $0.value
        })
        #expect(context.git.changedLineNumbers.files.keys.sorted()
            == ["Sources/After.swift", "Sources/App.swift", "Sources/New.swift"])
    }
}
