import DiffDiagnostics
import Foundation
import Testing

/// `steward`'s output on input that carries control characters, workflow
/// commands' syntax, and their escapes, run as its own process: text output
/// stays readable and on its lines, JSON reads back as the input, and the
/// runner reads no command but the annotations `--format github` writes.
@Suite("steward's output on hostile input")
struct CommandLineEscapingTests {
    /// Paths with a terminal escape and a carriage return, and with a
    /// property's separators, an escape spelled out, and the older `##[`
    /// command syntax. git quotes the first in a diff.
    static let controlPath = "e\u{1B}[31mf\r.swift"
    static let propertyPath = "p##[group]q,line=9,title=E%2C.swift"
    static let diff = #"""
        diff --git "a/e\033[31mf\r.swift" "b/e\033[31mf\r.swift"
        new file mode 100644
        --- /dev/null
        +++ "b/e\033[31mf\r.swift"
        @@ -0,0 +1 @@
        +let a = 1
        diff --git a/\#(propertyPath) b/\#(propertyPath)
        new file mode 100644
        --- /dev/null
        +++ b/\#(propertyPath)
        @@ -0,0 +1 @@
        +let b = 1

        """#
    static let message = "50% %0A done\r\n::error::injected\r##[error]legacy \u{1B}[2J\u{9B}"

    @Test("changes prints each path on its own line, with its control characters escaped")
    func changesText() throws {
        let output = try Self.steward(reading: [Self.diff]) { ["changes", $0[0], "--format", "text"] }
        #expect(output.split(separator: "\n", omittingEmptySubsequences: false) == [
            #"e\u{1B}[31mf\u{D}.swift:1"#, "\(Self.propertyPath):1", "",
        ])
    }

    @Test("changes' JSON reads back as the paths, and holds no workflow command")
    func changesJSON() throws {
        let output = try Self.steward(reading: [Self.diff]) { ["changes", $0[0], "--format", "json"] }
        let paths = try JSONDecoder().decode([Entry].self, from: Data(output.utf8)).map(\.path)
        #expect(paths == [Self.controlPath, Self.propertyPath])
        #expect(WorkflowCommand.commands(in: output).isEmpty)
    }

    @Test("filter's annotations each read as one command, with the path and the message as they are")
    func filterGitHub() throws {
        let output = try Self.filter("github")
        #expect(WorkflowCommand.commands(in: output) == [WorkflowCommand(
            name: "warning",
            properties: ["file": Self.propertyPath, "line": "1", "title": "rule,a:b"],
            data: Self.message
        )])
    }

    @Test("filter prints each diagnostic on one line, with its control characters escaped")
    func filterText() throws {
        let output = try Self.filter("text")
        #expect(output == """
            \(Self.propertyPath):1: warning: \
            50% %0A done\\u{D}\\u{A}::error::injected\\u{D}##[error]legacy \\u{1B}[2J\\u{9B} (rule,a:b)

            """)
    }

    @Test("filter's JSON reads back as the message, and holds no workflow command")
    func filterJSON() throws {
        let output = try Self.filter("json")
        let diagnostics = try JSONDecoder().decode([MatchedDiagnostic].self, from: Data(output.utf8))
        #expect(diagnostics.map(\.message) == [Self.message])
        #expect(WorkflowCommand.commands(in: output).isEmpty)
    }

    private struct Entry: Decodable {
        var path: String
    }

    /// `steward filter` on a SonarQube report of one issue on the second
    /// file, with the diff, in `format`.
    private static func filter(_ format: String) throws -> String {
        let issue: [String: Any] = [
            "component": "project:\(propertyPath)", "line": 1, "message": message,
            "rule": "rule,a:b", "severity": "MAJOR",
        ]
        let report = String(decoding: try JSONSerialization.data(withJSONObject: ["issues": [issue]]), as: UTF8.self)
        return try steward(reading: [report, diff]) {
            ["filter", $0[0], "--diff", $0[1], "--tool", "sonar", "--format", format]
        }
    }

    /// `steward`'s standard output, run with the arguments `arguments`
    /// makes from the paths of temporary files holding `inputs`.
    private static func steward(reading inputs: [String], _ arguments: ([String]) -> [String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-escaping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = try inputs.indices.map { index in
            let url = directory.appendingPathComponent("input-\(index)")
            try Data(inputs[index].utf8).write(to: url)
            return url.path
        }
        let output = try Subprocess.output(of: [try BuiltExecutable.required("steward").path] + arguments(paths))
        return String(decoding: output, as: UTF8.self)
    }
}
