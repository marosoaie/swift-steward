/// A place in the pull request's head commit: a file, and optionally a line.
public struct Location: Sendable, Hashable, Codable {
    /// The file's path from the repository's root, `/`-separated.
    public var path: String
    /// The 1-based line number in the head commit; nil for the file as a
    /// whole.
    public var line: Int?

    /// Creates a location in a file, or at one of its lines.
    public init(path: String, line: Int? = nil) {
        // Step 4.9's test commit, changed.
        var probe = path.count
        _ = probe
        self.path = path
        self.line = line
    }

    /// The report's JSON keys, a wire contract (docs/danger.md, section 4).
    enum CodingKeys: String, CodingKey {
        case path
        case line
    }
}
