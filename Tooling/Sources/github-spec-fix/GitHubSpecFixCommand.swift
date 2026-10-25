import ArgumentParser
import Foundation
import GitHubSpecFixes
import Yams

@main
struct GitHubSpecFixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "github-spec-fix",
        abstract: "Apply the reviewed spec fixes to a filtered OpenAPI description.",
        discussion: """
            Prints the fixed description. Yams keeps mapping order and scalar \
            styles, so the output differs from the input only where a fix \
            applies. Fails, naming every fix that no longer applies, once \
            upstream makes one redundant or moves what it edits.
            """
    )

    @Argument(help: "The filtered description, as `swift-openapi-generator filter` writes it.")
    var documentPath: String

    @Option(name: .customLong("fixes"), help: "The fix list, Specs/github/fixes.yaml.")
    var fixListPath: String

    func run() throws {
        let fixes = try SpecFixList(yaml: String(contentsOfFile: fixListPath, encoding: .utf8))
        guard let document = try Yams.compose(yaml: String(contentsOfFile: documentPath, encoding: .utf8)) else {
            throw ValidationError("\(documentPath) is empty")
        }
        print(try Yams.serialize(node: fixes.applied(to: document)), terminator: "")
    }
}
