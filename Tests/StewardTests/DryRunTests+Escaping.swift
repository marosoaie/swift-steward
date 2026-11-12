import Foundation
@testable import Steward
import Testing

extension DryRunTests {
    @Test("a dry run escapes the control characters in the summary it prints")
    func controlCharacters() async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        let recording = RecordingConsole()
        let rules = [Rule("Terminal") { _ in [.warning("red\u{1B}[31m\u{7}\u{9B}2J\tend")] }]
        _ = await Runner.testing(["--base", "main"], environment: [:], directory: fixture.repository.path,
                                 recording: recording)
            .run(rules)
        let (output, log) = await recording.finishStreams()
        #expect(output.contains(#"red\u{1B}[31m\u{7}\u{9B}2J\#tend"#))
        #expect(!(output + log).unicodeScalars.contains {
            $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
        })
    }

    @Test("a dry run breaks a workflow command's syntax in the summary it prints")
    func commandSyntax() async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        let recording = RecordingConsole()
        let rules = [Rule("Commands") { _ in [.markdown("::error::from a rule\n  ##[group]g"), .warning("w ##[x]")] }]
        _ = await Runner.testing(["--base", "main"], environment: [:], directory: fixture.repository.path,
                                 recording: recording)
            .run(rules)
        let (output, log) = await recording.finishStreams()
        #expect(output.contains(#"\u{3A}:error::from a rule"#))
        #expect(output.contains(#"#\u{23}[group]g"#))
        #expect(output.contains(#"w #\u{23}[x]"#))
        #expect(WorkflowCommand.commands(in: output + log).isEmpty)
    }
}
