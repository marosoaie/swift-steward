import GitDiffKit

/// A parsed `PathPattern`: what git's `:(glob)` pathspec matching does for
/// it (`match_pathspec_item` in git's `dir.c`), over a path's bytes.
///
/// Git matches a path when the pattern, as written, is the path or one of
/// its leading directories, or else when the pattern's wildcards match the
/// whole path. The second walks the pattern and the path together, keeping
/// the set of pattern positions each path byte can reach, so it takes at
/// most pattern length × path length steps and never backtracks.
struct PathMatcher: Sendable {
    private enum Token: Sendable {
        case byte(UInt8)
        /// `?`: any byte but `/`.
        case anyByte
        /// `*`: any bytes but `/`, or none.
        case anyBytesInComponent
        /// `**/`: none, or any bytes that end in `/`: any number of
        /// directories.
        case anyDirectories
        /// A final `**`: any bytes.
        case anyBytes

        /// Whether the token can match nothing where a path's component
        /// starts, or elsewhere: `**/` matches nothing only where it
        /// starts, which is always a component's start, and once it has
        /// matched bytes it must end with a `/`.
        func matchesNothing(atComponentStart: Bool) -> Bool {
            switch self {
            case .byte, .anyByte: false
            case .anyDirectories: atComponentStart
            case .anyBytesInComponent, .anyBytes: true
            }
        }
    }

    private let pattern: [UInt8]
    private let tokens: [Token]

    init(_ pattern: PathPattern) throws(PathPatternError) {
        let bytes = Array(pattern.description.utf8)
        try Self.checkComponents(of: pattern)
        var tokens: [Token] = []
        var index = 0
        // Imperative: a cursor that an escape or a run of stars moves by
        // more than one byte.
        while index < bytes.count {
            switch bytes[index] {
            case .backslash:
                guard index + 1 < bytes.count else {
                    throw PathPatternError(pattern: pattern, kind: .trailingBackslash)
                }
                tokens.append(.byte(bytes[index + 1]))
                index += 2
            case .openingBracket:
                throw PathPatternError(pattern: pattern, kind: .unescapedBracket)
            case .questionMark:
                tokens.append(.anyByte)
                index += 1
            case .star:
                let (token, end) = try Self.starToken(in: bytes, at: index, pattern: pattern)
                tokens.append(token)
                index = end
            case let byte:
                tokens.append(.byte(byte))
                index += 1
            }
        }
        // Checked last, so the `**` form the error suggests is well formed.
        if bytes.last == .slash, bytes.contains(where: { [.star, .questionMark, .backslash].contains($0) }) {
            throw PathPatternError(pattern: pattern, kind: .nonliteralDirectory)
        }
        self.pattern = bytes
        self.tokens = tokens
    }

    /// The token for the run of stars at `index`, and where the next one
    /// starts: two or more stars must be a whole component, as `**`.
    private static func starToken(
        in bytes: [UInt8],
        at index: Int,
        pattern: PathPattern
    ) throws(PathPatternError) -> (Token, end: Int) {
        let end = bytes[index...].firstIndex { $0 != .star } ?? bytes.count
        guard end - index > 1 else { return (.anyBytesInComponent, end) }
        let partialGlobstar = PathPatternError(pattern: pattern, kind: .partialGlobstar)
        guard index == 0 || bytes[index - 1] == .slash else { throw partialGlobstar }
        if end == bytes.count {
            return (.anyBytes, end)
        }
        guard bytes[end] == .slash else { throw partialGlobstar }
        return (.anyDirectories, end + 1)
    }

    /// Whether git's `:(glob)` pathspec matches `path`.
    func matches(_ path: DiffPath) -> Bool {
        matchesAsLeadingPath(path.bytes) || matchesAsGlob(path.bytes)
    }

    /// Whether the pattern matches either of `file`'s paths: the old path
    /// of a deletion or a rename, or the new path. A copy counts by its new
    /// path alone, as the file it creates.
    func matches(_ file: DiffFile) -> Bool {
        let paths =
            switch file.header.change {
            case .copied: [file.header.newPath]
            case .added, .deleted, .modified, .renamed: [file.header.oldPath, file.header.newPath]
            }
        return paths.contains { $0.map(matches) ?? false }
    }

    /// Git's checks of a pattern's components, before matching: it rejects
    /// a leading `/` and rewrites empty, `.` and `..` components away,
    /// which would make a pattern match what it doesn't say.
    private static func checkComponents(of pattern: PathPattern) throws(PathPatternError) {
        let text = pattern.description
        guard !text.isEmpty else { throw PathPatternError(pattern: pattern, kind: .empty) }
        guard !text.hasPrefix("/") else { throw PathPatternError(pattern: pattern, kind: .leadingSlash) }
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        // A trailing `/` is git's: `mbk/` matches what `mbk` does.
        let checked = components.last?.isEmpty == true ? components.dropLast() : components[...]
        if let component = checked.first(where: { ["", ".", ".."].contains($0) }) {
            throw PathPatternError(pattern: pattern, kind: .invalidComponent(String(component)))
        }
    }

    private func matchesAsLeadingPath(_ path: [UInt8]) -> Bool {
        path.starts(with: pattern)
            && (path.count == pattern.count || pattern.last == .slash || path[pattern.count] == .slash)
    }

    private func matchesAsGlob(_ path: [UInt8]) -> Bool {
        path.reduce(reachable(from: [0], atComponentStart: true)) { positions, byte in
            reachable(from: positions.lazy.flatMap { successors(of: $0, on: byte) }, atComponentStart: byte == .slash)
        }
        .contains(tokens.count)
    }

    /// `positions`, and every position after tokens that can match nothing
    /// there.
    private func reachable(from positions: some Sequence<Int>, atComponentStart: Bool) -> Set<Int> {
        positions.reduce(into: []) { reached, position in
            // Imperative: a chain stops at a position reached before, whose
            // chain is in already, so each position is visited once per path
            // byte; following every chain to its end would be quadratic in a
            // run of `**/`.
            var next = position
            while reached.insert(next).inserted, next < tokens.count,
                  tokens[next].matchesNothing(atComponentStart: atComponentStart) {
                next += 1
            }
        }
    }

    private func successors(of position: Int, on byte: UInt8) -> [Int] {
        guard position < tokens.count else { return [] }
        return switch tokens[position] {
        case .byte(let expected): byte == expected ? [position + 1] : []
        case .anyByte: byte == .slash ? [] : [position + 1]
        case .anyBytesInComponent: byte == .slash ? [] : [position]
        case .anyDirectories: byte == .slash ? [position, position + 1] : [position]
        case .anyBytes: [position]
        }
    }
}

private extension UInt8 {
    static let slash = UInt8(ascii: "/")
    static let backslash = UInt8(ascii: "\\")
    static let star = UInt8(ascii: "*")
    static let questionMark = UInt8(ascii: "?")
    static let openingBracket = UInt8(ascii: "[")
}
