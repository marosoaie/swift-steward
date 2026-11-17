import StewardTesting
import Testing

/// A rule that asks whether the changes overlap a range of a file's lines,
/// through the public API alone, as a Dangerfile's rule would.
@Suite("A rule that asks which lines changed")
struct ChangedLinesRuleTests {
    /// Warns on each changed file whose `lines` the pull request adds or
    /// rewrites, as a rule guarding a licence header would.
    static func header(_ lines: ClosedRange<Int>) -> Rule {
        Rule("Header") { context in
            (context.git.createdFiles + context.git.modifiedFiles)
                .filter { context.git.changedLines(in: $0).overlaps(lines) }
                .map { .warning("Changes lines \(lines.lowerBound)–\(lines.upperBound)", at: Location(path: $0)) }
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
        #expect(context.git.changedLines(in: "Sources/App.swift").ranges == [2...2])
        #expect(context.git.changedLines(in: "Sources/After.swift").ranges == [1...1])
        #expect(context.git.changedLines(in: "Docs/Old.md").isEmpty)
        #expect(context.git.changedLines.files.keys.sorted()
            == ["Sources/After.swift", "Sources/App.swift", "Sources/New.swift"])
    }
}
