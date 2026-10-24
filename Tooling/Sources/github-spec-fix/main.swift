import Foundation
import Yams

// Reads the filtered description, applies every fix in `SpecFix.all` in
// order, and prints the result. Yams keeps mapping order, so the output
// differs from the input only where a fix applies.
let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: github-spec-fix <filtered.yaml>\n".utf8))
    exit(2)
}
do {
    let text = try String(contentsOfFile: arguments[1], encoding: .utf8)
    guard let document = try Yams.compose(yaml: text) else {
        throw SpecFixError(message: "\(arguments[1]) is empty")
    }
    let fixed = try SpecFix.all.reduce(document) { document, fix in
        try fix.applied(to: document)
    }
    print(try Yams.serialize(node: fixed), terminator: "")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
