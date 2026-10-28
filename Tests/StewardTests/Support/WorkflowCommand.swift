/// A workflow command as the GitHub Actions runner reads one from a line of
/// a step's output, following actions/runner's `ActionCommand`: the `::`
/// form first (`TryParseV2`), and only when that fails, the older `##[`
/// one (`TryParse`), found anywhere in the line. Tests check with it what
/// a line means to GitHub, not only how it's spelled.
///
/// Any command name counts, where the runner takes only the ones it knows,
/// so a test sees every line that could be one. An older-form command
/// keeps its data as it is and no properties: tests only count those.
struct WorkflowCommand: Equatable {
    var name: String
    var properties: [String: String] = [:]
    var data: String

    /// The commands in `output`, which the runner reads a line at a time,
    /// breaking lines at `\n`, `\r`, and `\r\n`.
    static func commands(in output: String) -> [WorkflowCommand] {
        output.unicodeScalars
            .split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
            .compactMap { line in Self(line: Array(line)) ?? Self(legacyLine: Array(line)) }
    }
}

// In an extension, so the memberwise initializer stays.
extension WorkflowCommand {
    private init?(line: [Unicode.Scalar]) {
        let line = Array(line.drop { $0.properties.isWhitespace })
        guard line.starts(with: Self.key), let end = Self.index(of: Self.key, in: line, from: Self.key.count) else {
            return nil
        }
        let info = line[Self.key.count..<end]
        let name = info.prefix { $0 != " " }
        let rest = info.dropFirst(name.count + 1)
        let properties = Self.trimmed(Array(rest))
            .split(separator: ",")
            .compactMap { pair -> (String, String)? in
                guard let equals = pair.firstIndex(of: "="), equals > pair.startIndex,
                      equals < pair.index(before: pair.endIndex)
                else { return nil }
                let value = Self.unescaped(Array(pair[pair.index(after: equals)...]), mappings: Self.propertyMappings)
                return (Self.string(pair[..<equals]), value)
            }
        self.name = Self.string(name)
        // Later values replace earlier ones, as in the runner's dictionary.
        self.properties = Dictionary(properties, uniquingKeysWith: { _, later in later })
        data = Self.unescaped(Array(line[(end + Self.key.count)...]), mappings: Self.dataMappings)
    }

    private init?(legacyLine line: [Unicode.Scalar]) {
        guard let start = Self.index(of: ["#", "#", "["], in: line, from: 0),
              let close = line[(start + 3)...].firstIndex(of: "]")
        else { return nil }
        name = Self.string(line[(start + 3)..<close].prefix { $0 != " " })
        data = Self.string(line[(close + 1)...])
    }

    private static let key: [Unicode.Scalar] = [":", ":"]

    /// The runner's unescaping, in its order: each escape replaced in turn
    /// throughout, `%25` last.
    private static let dataMappings: [(String, String)] = [("%0D", "\r"), ("%0A", "\n"), ("%25", "%")]
    private static let propertyMappings: [(String, String)] = [
        ("%0D", "\r"), ("%0A", "\n"), ("%3A", ":"), ("%2C", ","), ("%25", "%"),
    ]

    private static func unescaped(_ scalars: [Unicode.Scalar], mappings: [(String, String)]) -> String {
        string(mappings.reduce(scalars) { text, mapping in
            replacing(Array(mapping.0.unicodeScalars), with: Array(mapping.1.unicodeScalars), in: text)
        })
    }

    /// `text` with every occurrence of `target`, left to right and not
    /// overlapping, replaced, as .NET's `String.Replace` does.
    private static func replacing(
        _ target: [Unicode.Scalar],
        with replacement: [Unicode.Scalar],
        in text: [Unicode.Scalar]
    ) -> [Unicode.Scalar] {
        guard let match = index(of: target, in: text, from: 0) else { return text }
        return Array(text[..<match]) + replacement
            + replacing(target, with: replacement, in: Array(text[(match + target.count)...]))
    }

    private static func index(of target: [Unicode.Scalar], in text: [Unicode.Scalar], from start: Int) -> Int? {
        guard start <= text.count - target.count else { return nil }
        return (start...(text.count - target.count)).first { text[$0..<($0 + target.count)].elementsEqual(target) }
    }

    private static func trimmed(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        Array(scalars.drop { $0.properties.isWhitespace }.reversed().drop { $0.properties.isWhitespace }.reversed())
    }

    private static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }
}
