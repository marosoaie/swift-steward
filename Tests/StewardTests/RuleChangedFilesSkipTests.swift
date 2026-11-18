@testable import Steward
import StewardTesting
import Testing

/// `Rule.changedFiles`' skips: each file it doesn't check is a finding of
/// the kind the rule asks for, beside its line in the log.
@Suite("Rule.changedFiles' skips")
struct RuleChangedFilesSkipTests {
    /// Creates a link, a submodule and `Big.swift`, renames `Old` to
    /// `Moved` with no mode, as git writes a link's or a submodule's rename,
    /// and creates `Gone.swift`, which `files` leaves out of the head.
    static let diff = #"""
        diff --git a/Link.swift b/Link.swift
        new file mode 120000
        index 0000000..1111111
        --- /dev/null
        +++ b/Link.swift
        @@ -0,0 +1 @@
        +Target.swift
        \ No newline at end of file
        diff --git a/Vendor b/Vendor
        new file mode 160000
        index 0000000..2222222
        --- /dev/null
        +++ b/Vendor
        @@ -0,0 +1 @@
        +Subproject commit 1234567890123456789012345678901234567890
        diff --git a/Big.swift b/Big.swift
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/Big.swift
        @@ -0,0 +1 @@
        +let big = 1
        diff --git a/Old b/Moved
        similarity index 100%
        rename from Old
        rename to Moved
        diff --git a/Gone.swift b/Gone.swift
        new file mode 100644
        index 0000000..4444444
        --- /dev/null
        +++ b/Gone.swift
        @@ -0,0 +1 @@
        +let gone = 1

        """#

    /// The head's files: `Big.swift`, and a directory at `Moved`.
    static let files = ["Big.swift": Array("let big = 1\n".utf8), "Moved/inside": Array("x\n".utf8)]

    /// A rule over every file, at a limit of 4 bytes, that checks nothing.
    static func rule(excluding excluded: PathPattern? = nil, kind: Finding.Kind = .warning) -> Rule {
        Rule.changedFiles("Skips", in: "**", excluding: excluded, limit: 4, reportingSkipsAs: kind) { _ in [] }
    }

    /// The context `diff` and `files` make, and a log that records.
    static func run(_ rule: Rule) async throws -> (findings: [Finding], log: [RecordingConsole.Entry]) {
        var context = try Context.fixture(diff: diff)
        context.localRepository = FakeLocalRepository([context.git.head: files])
        let recording = RecordingConsole()
        let findings = try await rule.check(context, Log(mode: .dryRun, console: recording.console))
        return (findings, await recording.finish())
    }

    @Test("each kind of skip is a finding of the kind the rule asks for, at the file, beside its log line",
          arguments: [Finding.Kind.failure, .warning, .message, .markdown])
    func kinds(kind: Finding.Kind) async throws {
        let (findings, log) = try await Self.run(Self.rule(kind: kind))
        #expect(findings == [
            RuleChangedFilesTests.skipped("Link.swift", "a symbolic link", by: "Skips", as: kind),
            RuleChangedFilesTests.skipped("Vendor", "a submodule", by: "Skips", as: kind),
            RuleChangedFilesTests.skipped("Big.swift", "12 bytes, over the limit of 4", by: "Skips", as: kind),
            RuleChangedFilesTests.skipped("Moved", "not a regular file at the head", by: "Skips", as: kind),
            // A failure whatever the skips' kind.
            .failure(
                "Couldn't check `Gone.swift`: the diff lists it at the head, and the head has no such file.",
                at: Location(path: "Gone.swift")
            ),
        ])
        #expect(log == [
            .error("Skips: skipped Link.swift, a symbolic link\n"),
            .error("Skips: skipped Vendor, a submodule\n"),
            .error("Skips: skipped Big.swift, 12 bytes, over the limit of 4\n"),
            .error("Skips: skipped Moved, not a regular file at the head\n"),
        ])
    }

    @Test("a skip is a warning unless the rule asks for another kind")
    func warningByDefault() async throws {
        let rule = Rule.changedFiles("Skips", in: "**", limit: 4) { _ in [] }
        let (findings, _) = try await Self.run(rule)
        #expect(findings.map(\.kind) == [.warning, .warning, .warning, .warning, .failure])
    }

    @Test("a file the exclusion matches is neither a finding nor a line in the log")
    func excluded() async throws {
        let (findings, log) = try await Self.run(Self.rule(excluding: "Link.swift"))
        #expect(findings.map(\.location?.path) == ["Vendor", "Big.swift", "Moved", "Gone.swift"])
        #expect(log == [
            .error("Skips: skipped Vendor, a submodule\n"),
            .error("Skips: skipped Big.swift, 12 bytes, over the limit of 4\n"),
            .error("Skips: skipped Moved, not a regular file at the head\n"),
        ])
    }

    @Test("a link whose name isn't UTF-8 is skipped by its name in git's quoting, at no location")
    func latin1Link() async throws {
        let diff = #"""
            diff --git "a/caf\351.swift" "b/caf\351.swift"
            new file mode 120000
            index 0000000..1111111
            --- /dev/null
            +++ "b/caf\351.swift"
            @@ -0,0 +1 @@
            +Target.swift
            \ No newline at end of file

            """#
        let context = try Context.fixture(diff: diff)
        let recording = RecordingConsole()
        let findings = try await Self.rule().check(context, Log(mode: .dryRun, console: recording.console))
        #expect(findings == [.warning(#"""
            Rule “Skips” skipped `caf\351.swift`, a symbolic link. A file the rule should never check belongs \#
            in its `excluding:` pattern.
            """#)])
        #expect(await recording.finish() == [.error(#"Skips: skipped caf\351.swift, a symbolic link"# + "\n")])
    }
}
