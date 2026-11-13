import GitDiffKit
@testable import Steward
import Testing

@Suite("Rule groups")
struct RuleGroupTests {
    struct Broken: Error, CustomStringConvertible {
        var description: String { "the labels are unreadable" }
    }

    // Named, as an inline condition before a group's trailing closure is
    // SwiftLint's multiple_closures_with_trailing_closure.
    private static let never: @Sendable (Context) -> Bool = { _ in false }
    private static let always: @Sendable (Context) -> Bool = { _ in true }
    private static let unreadable: @Sendable (Context) throws -> Bool = { _ in throw Broken() }

    private static func labelled(_ label: String) -> @Sendable (Context) -> Bool {
        { $0.pullRequest.labels.contains(label) }
    }

    /// Rules in a group on `Sources/**`, beside one in no group.
    struct GroupedChecks: Dangerfile {
        static var rules: [Rule] {
            Rule("Everywhere") { _ in [.message("everywhere")] }
            Rule.group(whenChangesMatch: "Sources/**") {
                Rule("Lint") { _ in [.warning("lint")] }
                Rule("Format") { _ in [.message("format")] }
            }
        }
    }

    /// The README's and docs/rule-tests.md's group.
    struct DocumentedGroup: Dangerfile {
        static var rules: [Rule] {
            sources
        }

        static let sources = Rule.group(whenChangesMatch: "Sources/**") {
            Rule("Tests") { context in
                try context.git.changes(matching: "Tests/**").diff.files.isEmpty
                    ? [.warning("Changes Sources without changing Tests.")] : []
            }
        }
    }

    private static func edit(_ path: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..2222222 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -1 +1 @@
        -old
        +new

        """
    }

    private static let rename = """
        diff --git a/Sources/Old.swift b/Moved/New.swift
        similarity index 100%
        rename from Sources/Old.swift
        rename to Moved/New.swift

        """

    private static func run(
        _ rules: [Rule],
        on diff: String,
        mode: Run.Mode = .dryRun
    ) async throws -> (findings: [Finding], log: [RecordingConsole.Entry]) {
        let recording = RecordingConsole()
        let findings = try await rules.findings(in: .stub(diff: diff), log: Log(mode: mode, console: recording.console))
        return (findings, await recording.finish())
    }

    @Test("a group's rules run when a changed file matches its pattern")
    func matching() async throws {
        let (findings, log) = try await Self.run(GroupedChecks.rules, on: Self.edit("Sources/A.swift"))
        #expect(findings.map(\.rule) == ["Everywhere", "Lint", "Format"])
        #expect(log == [.error("Everywhere: 1 finding\n"), .error("Lint: 1 finding\n"), .error("Format: 1 finding\n")])
    }

    @Test("a group's rules are skipped, on the log's standard error, when no changed file matches", arguments: [
        Run.Mode.dryRun, .actions,
    ])
    func skipped(mode: Run.Mode) async throws {
        let (findings, log) = try await Self.run(GroupedChecks.rules, on: Self.edit("docs/Sources.md"), mode: mode)
        #expect(findings.map(\.rule) == ["Everywhere"])
        #expect(log == [
            .error("Everywhere: 1 finding\n"),
            .error("Lint: skipped, no changed file matches Sources/**\n"),
            .error("Format: skipped, no changed file matches Sources/**\n"),
        ])
    }

    @Test("the documented group warns where Sources changes without Tests, and skips elsewhere")
    func documented() async throws {
        let sourcesOnly = try await Self.run(DocumentedGroup.rules, on: Self.edit("Sources/A.swift"))
        let both = Self.edit("Sources/A.swift") + Self.edit("Tests/T.swift")
        let withTests = try await Self.run(DocumentedGroup.rules, on: both)
        let docs = try await Self.run(DocumentedGroup.rules, on: Self.edit("README.md"))
        #expect(sourcesOnly.findings.map(\.text) == ["Changes Sources without changing Tests."])
        #expect(withTests.findings.isEmpty)
        #expect(docs.log == [.error("Tests: skipped, no changed file matches Sources/**\n")])
    }

    @Test("an empty diff skips every path group")
    func emptyDiff() async throws {
        let (findings, _) = try await Self.run(GroupedChecks.rules, on: "")
        #expect(findings.map(\.rule) == ["Everywhere"])
    }

    @Test("a rename runs a group that matches either of its paths")
    func rename() async throws {
        let rules = Rule.group(whenChangesMatch: "Sources/**") { Rule("Old") { _ in [.message("old")] } }
            + Rule.group(whenChangesMatch: "Moved/*") { Rule("New") { _ in [.message("new")] } }
        let (findings, _) = try await Self.run(rules, on: Self.rename)
        #expect(findings.map(\.rule) == ["Old", "New"])
    }

    @Test("a damaged diff runs a path group, since the file it lost might match")
    func damagedDiff() async throws {
        // A header over the parser's 64 lines: the file is abandoned.
        let diff = """
            diff --git a/docs/a.md b/docs/a.md
            \(String(repeating: "old mode 100644\n", count: 70))\
            --- a/docs/a.md
            +++ b/docs/a.md

            """
        #expect(!Diff(diff: diff).damage.isEmpty)
        let (findings, _) = try await Self.run(GroupedChecks.rules, on: diff)
        #expect(findings.map(\.rule) == ["Everywhere", "Lint", "Format"])
    }

    @Test("nested groups combine, outermost first, and the log gives the first that doesn't hold")
    func nesting() async throws {
        let rules = Rule.group(when: Self.labelled("outer"), skipReason: "no outer label") {
            Rule("Outer only") { _ in [.message("outer")] }
            Rule.group(when: Self.labelled("inner"), skipReason: "no inner label") {
                Rule("Both") { _ in [.message("both")] }
            }
        }
        let recording = RecordingConsole()
        let log = Log(mode: .dryRun, console: recording.console)
        let outer = try await rules.findings(in: .stub(labels: ["outer"]), log: log)
        let neither = try await rules.findings(in: .stub(labels: ["inner"]), log: log)
        let both = try await rules.findings(in: .stub(labels: ["outer", "inner"]), log: log)
        #expect(outer.map(\.rule) == ["Outer only"])
        #expect(neither.isEmpty)
        #expect(both.map(\.rule) == ["Outer only", "Both"])
        #expect(await recording.finish() == [
            .error("Outer only: 1 finding\n"), .error("Both: skipped, no inner label\n"),
            .error("Outer only: skipped, no outer label\n"), .error("Both: skipped, no outer label\n"),
            .error("Outer only: 1 finding\n"), .error("Both: 1 finding\n"),
        ])
    }

    @Test("an outer group that doesn't hold skips the rule before an inner condition runs")
    func outerFirst() async throws {
        let rules = Rule.group(when: Self.never, skipReason: "off") {
            Rule.group(when: Self.unreadable, skipReason: "never") { Rule("Inner") { _ in [] } }
        }
        let (findings, log) = try await Self.run(rules, on: "")
        #expect(findings.isEmpty)
        #expect(log == [.error("Inner: skipped, off\n")])
    }

    @Test("what a condition throws, or a malformed pattern, is each rule's failure, and none of them runs")
    func failingConditions() async throws {
        let rules = Rule.group(when: Self.unreadable, skipReason: "unused") {
            Rule("Labels") { _ in [.message("ran")] }
        } + Rule.group(whenChangesMatch: "Sources/[ab]") {
            Rule("First") { _ in [.message("ran")] }
            Rule("Second") { _ in [.message("ran")] }
        }
        let (findings, log) = try await Self.run(rules, on: Self.edit("Sources/a"))
        #expect(findings.map(\.kind) == [.failure, .failure, .failure])
        #expect(findings.map(\.rule) == ["Labels", "First", "Second"])
        #expect(findings[0].text == "Rule “Labels” failed: the labels are unreadable")
        #expect(findings[1].text == """
            Rule “First” failed: The path pattern “Sources/\\[ab\\]” has an unescaped “\\[”; classes aren't \
            supported, so write \\\\\\[ for a literal one.
            """)
        #expect(log.last == .error("Second: 1 finding, 1 failing\n"))
    }

    @Test("evaluate and applies(to:) give what a run gives, and setting evaluate keeps the groups")
    func evaluate() async throws {
        var rule = try #require(GroupedChecks.rules.last)
        let matching = Context.stub(diff: Self.edit("Sources/A.swift"))
        let elsewhere = Context.stub(diff: Self.edit("README.md"))
        #expect(try rule.applies(to: matching))
        #expect(try !rule.applies(to: elsewhere))
        #expect(try await rule.evaluate(matching).map(\.text) == ["format"])
        #expect(try await rule.evaluate(elsewhere).isEmpty)

        rule.evaluate = { _ in [.failure("replaced")] }
        #expect(try await rule.evaluate(matching).map(\.text) == ["replaced"])
        #expect(try await rule.evaluate(elsewhere).isEmpty)
        #expect(try await [rule].findings(in: elsewhere, log: .discarding).isEmpty)
    }

    @Test("a rule in no group applies everywhere, and a malformed pattern throws from evaluate and applies(to:)")
    func ungroupedAndMalformed() async throws {
        let plain = Rule("Plain") { _ in [] }
        #expect(try plain.applies(to: .stub()))
        let malformed = try #require(Rule.group(whenChangesMatch: "/Sources") { plain }.first)
        #expect(throws: PathPatternError.leadingSlash("/Sources")) { try malformed.applies(to: .stub()) }
        await #expect(throws: PathPatternError.leadingSlash("/Sources")) { try await malformed.evaluate(.stub()) }
    }

    @Test("groups build inside a rule builder: nested, in an if, and beside plain rules")
    func building() {
        @RuleBuilder
        func rules(strict: Bool) -> [Rule] {
            Rule("Plain") { _ in [] }
            if strict {
                Rule.group(whenChangesMatch: "a/**") {
                    Rule("A") { _ in [] }
                    Rule.group(when: Self.always, skipReason: "inner") { Rule("Inner") { _ in [] } }
                }
            }
        }
        #expect(rules(strict: false).map(\.name) == ["Plain"])
        #expect(rules(strict: true).map(\.name) == ["Plain", "A", "Inner"])
        #expect(rules(strict: true).map(\.conditions.count) == [0, 1, 2])
        #expect(rules(strict: true).last?.conditions.map(\.skipReason) == ["no changed file matches a/**", "inner"])
    }
}
