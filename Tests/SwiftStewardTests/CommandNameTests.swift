import Foundation
import Testing

/// The tool ships as `steward` (it was `git-diff-parser` up to v1.0.2); its
/// help must use the new name throughout, examples included.
@Suite("Command name")
struct CommandNameTests {
    @Test(
        "help introduces the tool as steward and never by its old name",
        arguments: [[], ["changes"], ["filter"]]
    )
    func helpUsesTheNewName(subcommand: [String]) throws {
        let help = String(decoding: try CommandLineTool.run(arguments: subcommand + ["--help"]), as: UTF8.self)
        let usage = (["steward"] + subcommand).joined(separator: " ")
        #expect(help.contains("USAGE: \(usage) "))
        #expect(!help.contains("git-diff-parser"))
    }

    @Test("the built executable is named steward")
    func executableName() throws {
        let tool = try #require(CommandLineTool.url)
        #expect(tool.lastPathComponent == "steward")
    }
}
