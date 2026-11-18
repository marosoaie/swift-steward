@testable import Steward
import StewardTesting
import Testing

/// `Finding.skipped`: the finding `Rule.changedFiles` reports for a file it
/// skips, for a check's own skips.
@Suite("Finding.skipped")
struct FindingSkippedTests {
    @Test("the factory gives the finding the rule reports for the same skip, of each kind",
          arguments: [Finding.Kind.failure, .warning, .message, .markdown])
    func sameAsTheRule(kind: Finding.Kind) async throws {
        let rule = RuleChangedFilesSkipTests.rule(kind: kind)
        let (findings, _) = try await RuleChangedFilesSkipTests.run(rule)
        try #require(findings.count == 5)
        // The link, the submodule, and the link the diff renames with no
        // mode; not the file over the limit, whose text only the rule has.
        #expect([findings[0], findings[1], findings[3]] == [
            .skipped("Link.swift", "a symbolic link", by: "Skips", as: kind),
            .skipped("Vendor", "a submodule", by: "Skips", as: kind),
            .skipped("Moved", "not a regular file at the head", by: "Skips", as: kind),
        ])
    }

    @Test("a rule's name with Markdown in it is escaped and a path is a code span, as in the rule's own skip")
    func markdown() async throws {
        let name = "Licence @org/team for #12 *now*"
        let path = "*b*`c`@org#12.swift"
        let context = try Context.fixture(diff: """
            diff --git a/\(path) b/\(path)
            new file mode 120000
            index 0000000..1111111
            --- /dev/null
            +++ b/\(path)
            @@ -0,0 +1 @@
            +Target.swift
            \\ No newline at end of file

            """)
        let findings = try await Rule.changedFiles(name, in: "**") { _ in [] }.evaluate(context)
        let skipped = Finding.skipped(path, "a symbolic link", by: name)
        #expect(findings == [skipped])
        #expect(skipped == .warning(#"""
            Rule “Licence @\#u{200B}org/team for #\#u{200B}12 \*now\*” skipped ``*b*`c`@org#12.swift``, a symbolic \#
            link. A file the rule should never check belongs in its `excluding:` pattern.
            """#, at: Location(path: path)))
    }

    @Test("the reason goes in as written, and the factory writes nothing to the log")
    func reasonAsWritten() async throws {
        let recording = RecordingConsole()
        let rule = Rule.changedFiles("Swift", in: "**") { file, _ in
            [.skipped(file.path, "with *syntax* errors", by: "Swift", as: .message)]
        }
        let context = try Context.fixture(diff: """
            diff --git a/New.swift b/New.swift
            new file mode 100644
            index 0000000..1111111
            --- /dev/null
            +++ b/New.swift
            @@ -0,0 +1 @@
            +struct New {

            """, files: ["New.swift": "struct New {\n"])
        let findings = try await rule.check(context, Log(mode: .dryRun, console: recording.console))
        #expect(findings == [.message("""
            Rule “Swift” skipped `New.swift`, with *syntax* errors. A file the rule should never check belongs \
            in its `excluding:` pattern.
            """, at: Location(path: "New.swift"))])
        #expect(await recording.finish().isEmpty)
    }
}
