import BuildLogKit
import DiffDiagnostics
@testable import Steward
import Testing

/// Findings as annotations in Files changed (docs/danger.md, section 6),
/// read back as the Actions runner reads them (`WorkflowCommand`).
@Suite("Findings as annotations")
struct AnnotationTests {
    @Test("a located failure, warning, and message are an error, a warning, and a notice on their line", arguments: [
        (Finding.Kind.failure, "error"), (.warning, "warning"), (.message, "notice"),
    ])
    func kinds(kind: Finding.Kind, command: String) throws {
        let location = Location(path: "Sources/A.swift", line: 12)
        let finding = Finding(kind: kind, text: "Unused variable", location: location)
        let annotation = try #require(Log.annotation(of: finding))
        #expect(annotation == "::\(command) file=Sources/A.swift,line=12,title=Steward::Unused variable\n")
        #expect(WorkflowCommand.commands(in: annotation) == [WorkflowCommand(
            name: command,
            properties: ["file": "Sources/A.swift", "line": "12", "title": "Steward"],
            data: "Unused variable"
        )])
    }

    @Test("a location without a line annotates the file")
    func wholeFile() {
        #expect(Log.annotation(of: .warning("Write it in Swift.", at: Location(path: "Legacy.m")))
            == "::warning file=Legacy.m,title=Steward::Write it in Swift.\n")
    }

    @Test("a finding without a location, or a markdown one, gets no annotation", arguments: [
        Finding.failure("Adds more than 1000 lines"),
        .warning("Add a CHANGELOG entry."),
        .message("Changes 3 files"),
        .markdown("- a list", at: Location(path: "README.md", line: 1)),
    ])
    func none(finding: Finding) {
        #expect(Log.annotation(of: finding) == nil)
    }

    @Test("in CI, each located finding is annotated in order; a dry run annotates none")
    func modes() async {
        let findings: [Finding] = [
            .message("Changes 3 files"),
            .failure("Broken", at: Location(path: "b.swift", line: 2)),
            .markdown("**Notes**", at: Location(path: "a.swift", line: 1)),
            .message("First added line", at: Location(path: "a.swift", line: 1)),
        ]
        let actions = RecordingConsole()
        Log(mode: .actions, console: actions.console).annotate(findings)
        #expect(await actions.finish() == [
            .error("::error file=b.swift,line=2,title=Steward::Broken\n"),
            .error("::notice file=a.swift,line=1,title=Steward::First added line\n"),
        ])
        let dryRun = RecordingConsole()
        Log(mode: .dryRun, console: dryRun.console).annotate(findings)
        #expect(await dryRun.finish().isEmpty)
    }

    @Test("the built-in rule's escaping is undone, so the tool's message reads as it wrote it")
    func plainText() throws {
        let message = #"Use `x` *now*, @ada: see #12 and GH-3 in C:\logs\[1] <b>&amp;</b> ~a~ 100%"#
        let diagnostic = MatchedDiagnostic(path: "A.swift", line: 3, severity: .warning, message: message, rule: "a`b")
        let finding = ChangedLineDiagnostics.finding(for: diagnostic, failingOn: .error)
        #expect(finding.text != "\(message) (``a`b``)")
        let annotation = try #require(Log.annotation(of: finding))
        #expect(WorkflowCommand.commands(in: annotation).map(\.data) == ["\(message) (``a`b``)"])
    }

    @Test("a property value escapes what would end it, as well as what data escapes")
    func propertyEscaping() {
        #expect(Log.escapedProperty("50% a\r\nb:c,d=e") == "50%25 a%0D%0Ab%3Ac%2Cd=e")
        // A combining mark makes one Character of each, but the runner
        // splits at the `:` and the `,` all the same.
        #expect(Log.escapedProperty(":\u{301},\u{301}") == "%3A\u{301}%2C\u{301}")
        #expect(Log.escapedData("a:b,c") == "a:b,c")
    }

    /// A path and a text that try every way out of their places: a line
    /// break of each kind, a new command, the older `##[` syntax, a
    /// property separator, the end of the properties, combining marks,
    /// and escapes spelled out, which must stay text.
    static let hostilePath = "a,line=99,title=Evil::b:\u{301}c,\u{301}d%2C%3A\r\n::error::path"
    static let hostileText = """
        50% %0A %25 done\r\n::error file=README.md,line=1::injected\r##[error]legacy\n  ::notice::indented\u{301}
        """

    @Test("hostile text and paths can't add a command or a property, and read back as they are")
    func hostile() throws {
        let finding = Finding.warning(Self.hostileText, at: Location(path: Self.hostilePath, line: 7))
        let annotation = try #require(Log.annotation(of: finding))
        #expect(annotation.utf8.filter { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }.count == 1)
        #expect(WorkflowCommand.commands(in: annotation) == [WorkflowCommand(
            name: "warning",
            properties: ["file": Self.hostilePath, "line": "7", "title": "Steward"],
            data: Self.hostileText
        )])
        // The check above catches a missing escape: the same command
        // written without them reads as several, with other properties.
        let raw = "::warning file=\(Self.hostilePath),line=7,title=Steward::\(Self.hostileText)\n"
        #expect(WorkflowCommand.commands(in: raw).count > 1)
        #expect(WorkflowCommand.commands(in: raw).first?.properties["file"] != Self.hostilePath)
    }
}
