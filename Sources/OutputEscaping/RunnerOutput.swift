import Foundation

/// Text for the GitHub Actions runner, which reads a step's output for
/// workflow commands: Steward's log, and `steward filter`'s annotations.
/// Much of that text comes from a pull request, so it must never pass for
/// a command, which could mask values, end a group, or add annotations.
package enum RunnerOutput {
    /// A new token for `::stop-commands::`, which pauses workflow commands
    /// around untrusted text. It must be unpredictable, or the text could
    /// end the pause itself.
    package static func newStopToken() -> String {
        UUID().uuidString
    }

    /// `text` as a workflow command's data, which must stay on the
    /// command's line.
    package static func escapedData(_ text: String) -> String {
        escaped(text, isProperty: false)
    }

    /// `text` as the value of a workflow command's property, which must
    /// also not end the value (`,`) or the properties (`::`).
    package static func escapedProperty(_ text: String) -> String {
        escaped(text, isProperty: true)
    }

    private static func escaped(_ text: String, isProperty: Bool) -> String {
        // Over scalars: "\r\n" is one Character, and both of its halves
        // need escaping, as does a `:` or `,` a combining mark follows.
        text.unicodeScalars.reduce(into: "") { escaped, scalar in
            switch scalar {
            case "%": escaped += "%25"
            case "\r": escaped += "%0D"
            case "\n": escaped += "%0A"
            case ":" where isProperty: escaped += "%3A"
            case "," where isProperty: escaped += "%2C"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
    }

    /// Whether the runner could read a line of `text` as a workflow
    /// command: one that starts with `::` once its leading whitespace is
    /// trimmed, as the runner trims it, or one with the older `##[` syntax,
    /// which the runner finds anywhere in a line. Both line breaks count,
    /// as they do for the runner.
    package static func couldHoldCommands(_ text: String) -> Bool {
        text.unicodeScalars.contains("##[".unicodeScalars)
            || text.unicodeScalars
                .split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
                .contains { $0.drop { $0.properties.isWhitespace }.starts(with: "::".unicodeScalars) }
    }
}
