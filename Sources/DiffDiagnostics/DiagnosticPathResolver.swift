/// Resolves the paths diagnostics carry, usually absolute, to the
/// repository-relative paths a diff uses: the matching behind
/// `DiagnosticMatcher`, for callers that resolve before they match, such as
/// one that maps lines from one tree to another first.
///
/// A log path resolves to itself, once `repoRoot` is stripped from its
/// start, when that is one of the known paths. Otherwise it resolves to the
/// longest known path it ends with, aligned on a `/` so that `Bar.swift`
/// doesn't match `FooBar.swift`; so the root is rarely needed. Results are
/// cached per log path, so a long log costs one scan of the known paths for
/// each distinct path it names.
package struct DiagnosticPathResolver: Sendable {
    private let paths: Set<String>
    /// `repoRoot` ending in `/`.
    private let root: String?
    private var resolved: [String: String?] = [:]

    /// Creates a resolver that resolves log paths to `paths`, stripping
    /// `repoRoot`, such as the checkout's directory, from log paths that
    /// start with it.
    package init(paths: some Sequence<String>, repoRoot: String? = nil) {
        self.paths = Set(paths)
        root = repoRoot.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    /// The known path `logPath` names, or nil when it names none of them.
    package mutating func resolve(_ logPath: String) -> String? {
        if let cached = resolved[logPath] { return cached }
        let path = resolvedUncached(logPath)
        resolved[logPath] = path
        return path
    }

    private func resolvedUncached(_ logPath: String) -> String? {
        let path = root.flatMap { logPath.hasPrefix($0) ? String(logPath.dropFirst($0.count)) : nil } ?? logPath
        if paths.contains(path) { return path }
        return paths
            .filter { path == $0 || path.hasSuffix("/" + $0) }
            .max { $0.count < $1.count }
    }
}
