import GitDiffKit
@testable import Steward
import Testing

@Suite("The run's log")
struct LogTests {
    @Test("a dry run logs plain lines, without groups or workflow commands")
    func dryRun() async {
        let recording = RecordingConsole()
        let log = Log(mode: .dryRun, console: recording.console)
        await log.group("Rules") {
            log.write("::set-output name=x::y")
            log.warning("Careful\nnow")
            log.error("Broken")
        }
        #expect(await recording.finish() == [
            .error("::set-output name=x::y\n"), .error("warning: Careful\nnow\n"), .error("error: Broken\n"),
        ])
    }

    @Test("in CI, warnings and errors are annotations whose data stays on one line")
    func annotations() async {
        let recording = RecordingConsole()
        let log = Log(mode: .actions, console: recording.console)
        log.warning("50% done\r\nnext\n")
        log.error("::endgroup::")
        #expect(await recording.finish() == [
            .error("::warning title=Steward::50%25 done%0D%0Anext%0A\n"),
            .error("::error title=Steward::::endgroup::\n"),
        ])
    }

    /// Text that could pass for a workflow command. The tests take the
    /// case, not its text, because swift-testing prints its arguments and
    /// the runner would take the text for commands in that output too.
    enum Disguise: CaseIterable {
        case command, indented, afterCarriageReturn, afterNonBreakingSpace, legacySyntax, combiningMark

        var text: String {
            switch self {
            case .command: "::add-mask::secret"
            case .indented: "Files:\n  \t::endgroup::"
            case .afterCarriageReturn: "one\r::error::two"
            case .afterNonBreakingSpace: "\u{00A0}::warning::non-breaking space"
            case .legacySyntax: "a ##[error]legacy syntax anywhere"
            case .combiningMark: "##[\u{301}error]: [ and a combining mark are one Character"
            }
        }
    }

    @Test(
        "in CI, text that could pass for a workflow command is logged with commands paused",
        arguments: Disguise.allCases
    )
    func pausedCommands(disguise: Disguise) async {
        let recording = RecordingConsole()
        Log(mode: .actions, console: recording.console, makeToken: { "T0K3N" }).write(disguise.text)
        #expect(await recording.finish() == [.error("::stop-commands::T0K3N\n\(disguise.text)\n::T0K3N::\n")])
    }

    @Test("in CI, text with :: only inside its lines is logged as it is")
    func harmlessText() async {
        let recording = RecordingConsole()
        Log(mode: .actions, console: recording.console, makeToken: { "T0K3N" }).write("a::b\nstd::vector\n")
        #expect(await recording.finish() == [.error("a::b\nstd::vector\n")])
    }

    @Test("the pause token is unpredictable, a new one each time")
    func tokens() {
        let log = Log(mode: .actions, console: RecordingConsole().console)
        #expect(log.makeToken() != log.makeToken())
    }

    @Test("in CI, a group folds what it logs, and closes when its body throws")
    func groups() async {
        let recording = RecordingConsole()
        let log = Log(mode: .actions, console: recording.console)
        await log.group("Context\n50%") { log.write("inside") }
        await #expect(throws: CancellationError.self) {
            try await log.group("Rules") { () throws(CancellationError) in throw CancellationError() }
        }
        #expect(await recording.finish() == [
            .error("::group::Context%0A50%25\n"), .error("inside\n"), .error("::endgroup::\n"),
            .error("::group::Rules\n"), .error("::endgroup::\n"),
        ])
    }

    @Test("an abandoned file in the diff is a warning, a local recovery a line of the log")
    func damage() async throws {
        let diff = Diff(diff: """
            diff --git a/a.swift b/a.swift
            --- a/a.swift
            +++ b/a.swift
            @@ -1,2 +1,2 @@
             one
            two

            """)
        let recovery = try #require(diff.damage.first)
        let header = try #require(diff.files.first?.header)
        let abandoned = DamageReport(reason: .headerTooLarge, lineNumber: 9, file: header)
        let outside = DamageReport(reason: .hunkWithoutFile, lineNumber: 1, file: nil)

        let recording = RecordingConsole()
        Log(mode: .actions, console: recording.console).record([recovery, abandoned, outside])
        #expect(await recording.finish() == [
            .error("The diff is damaged at line 6 (a.swift): a hunk line has no +, -, or space marker.\n"),
            .error("""
                ::warning title=Steward::The diff is damaged at line 9 (a.swift): the file's header is too \
                large. Steward left the file out, so the rules didn't see it.

                """),
            .error("The diff is damaged at line 1: a hunk comes before any file header.\n"),
        ])
    }
}
