import BuildLogKit
import DiffDiagnostics
import Foundation
import GitDiffKit

/// The work behind `Rule.diagnosticsOnChangedLines(in:failingOn:)`
/// (docs/danger.md, section 3): each source's diagnostics, mapped from the
/// tree it was built from to the head commit, and matched against the
/// lines the pull request adds.
enum ChangedLineDiagnostics {
    /// The findings of every source, in the sources' order, failures at or
    /// above `threshold`, with what became of each source's diagnostics
    /// logged. A diagnostic that matches one an earlier source gave in
    /// every part, column included, is left out: two builds of one package,
    /// for two platforms, give each of its warnings twice. A source's own
    /// repeats stay, as `steward filter` keeps them.
    static func findings(
        for sources: [DiagnosticSource],
        failingOn threshold: DiagnosticSeverity,
        in context: Context,
        log: Log
    ) async throws -> [Finding] {
        let changes = context.git.addedLines
        let lineMaps = await lineMaps(for: sources, in: context)
        var findings: [Finding] = []
        var reported: Set<MatchedDiagnostic> = []
        // Imperative: each source awaits its read, which `reduce` can't.
        for source in sources {
            try Task.checkCancellation()
            let result = await diagnosticsOnChangedLines(
                of: source,
                in: context,
                changes: changes,
                lineMaps: lineMaps,
                log: log
            )
            switch result {
            case .success(let matched):
                let new = matched.filter { !reported.contains($0) }
                reported.formUnion(matched)
                if new.count < matched.count {
                    log.write("""
                        \(source.kind) \(source.path): \(count(matched.count - new.count, "diagnostic")) \
                        on changed lines left out, the same as one an earlier report gave
                        """)
                }
                findings += new.map { finding(for: $0, failingOn: threshold) }
            case .failure(let unreadable): findings.append(.failure(unreadable.text))
            }
        }
        return findings
    }

    /// The source's diagnostics on lines the pull request adds, at their
    /// head locations, or why the source couldn't be read.
    private static func diagnosticsOnChangedLines(
        of source: DiagnosticSource,
        in context: Context,
        changes: ChangedLines,
        lineMaps: [String: Result<LineMap, LineMapError>],
        log: Log
    ) async -> Result<[MatchedDiagnostic], UnreadableSource> {
        let lineMap: LineMap
        switch source.builtCommit.flatMap({ lineMaps[$0] }) ?? .success(context.run.lineMap) {
        case .success(let map): lineMap = map
        case .failure(let error): return .failure(UnreadableSource(text: error.text(for: source)))
        }
        let diagnostics: [Diagnostic]
        do {
            diagnostics = try await source.diagnostics(relativeTo: context.run.workspace)
        } catch {
            let reason = Markdown.escaped(String(errorDescription: error))
            return .failure(UnreadableSource(
                text: "Couldn't read the \(source.kind) \(Markdown.codeSpan(source.path)): \(reason)"
            ))
        }
        let (matched, dropped) = Self.matched(
            diagnostics,
            lineMap: lineMap,
            changes: changes,
            workspace: context.run.workspace
        )
        log.write("""
            \(source.kind) \(source.path): \(count(diagnostics.count, "diagnostic")), \
            \(matched.count) on changed lines, \(dropped) dropped for lines the head commit doesn't have
            """)
        return .success(matched)
    }

    /// A source that gave no diagnostics, with its failure finding's text.
    private struct UnreadableSource: Error {
        let text: String
    }

    /// Why a source's commit has no line map.
    private enum LineMapError: Error {
        /// The checkout has no commit by that name.
        case missingCommit
        /// Git failed, as the description says.
        case git(String)

        func text(for source: DiagnosticSource) -> String {
            let commit = Markdown.codeSpan(source.builtCommit ?? "")
            let subject = "The \(source.kind) \(Markdown.codeSpan(source.path)), built at \(commit)"
            return switch self {
            case .missingCommit: "\(subject), can't be read: the checkout has no such commit."
            case .git(let reason):
                "\(subject), can't be read: its lines don't map to the head. \(Markdown.escaped(reason))"
            }
        }
    }

    /// The line maps from the commits the sources name with `builtAt:` to
    /// the head, by the names they give, each read once.
    private static func lineMaps(
        for sources: [DiagnosticSource],
        in context: Context
    ) async -> [String: Result<LineMap, LineMapError>] {
        let git = Git(directory: context.run.workspace)
        var maps: [String: Result<LineMap, LineMapError>] = [:]
        // Imperative: each map awaits git, which `reduce` can't.
        for name in Set(sources.compactMap(\.builtCommit)).sorted() {
            maps[name] = await lineMap(builtAt: name, in: context, git: git)
        }
        return maps
    }

    private static func lineMap(
        builtAt name: String,
        in context: Context,
        git: Git
    ) async -> Result<LineMap, LineMapError> {
        do {
            guard let built = try await git.commit(named: name) else { return .failure(.missingCommit) }
            if built == context.run.builtCommit { return .success(context.run.lineMap) }
            return .success(try await LineMap(built: built, head: context.git.head, git: git))
        } catch {
            return .failure(.git(String(errorDescription: error)))
        }
    }

    /// The diagnostics on lines `changes` adds, at their head locations and
    /// sorted as `DiagnosticMatcher` sorts them, and how many were dropped
    /// because the head commit doesn't have their lines: the base or the
    /// merge changed them, or their file is new in the built commit.
    ///
    /// Log paths resolve against the pull request's paths and every path
    /// the line map knows, so a file the base renamed is found under its
    /// built path. Once `workspace` is stripped, a path naming a file in the
    /// checkout is that file; any other resolves as `steward filter
    /// --repo-root <workspace>` resolves it, by its longest known suffix.
    static func matched(
        _ diagnostics: [Diagnostic],
        lineMap: LineMap,
        changes: ChangedLines,
        workspace: String
    ) -> (matched: [MatchedDiagnostic], dropped: Int) {
        var resolver = DiagnosticPathResolver(
            paths: Set(changes.files.keys).union(lineMap.files.keys),
            repoRoot: workspace,
            existsInCheckout: existsInCheckout(at: workspace)
        )
        // A diagnostic whose path resolves to none of these is in a file
        // that neither side changed: its lines are the head's, and none of
        // them is on a changed line.
        let located = diagnostics.compactMap { diagnostic -> (Diagnostic, Location?)? in
            resolver.resolve(diagnostic.path).map { path in
                (diagnostic, lineMap.headLocation(ofLine: diagnostic.line, inFile: path))
            }
        }
        let mapped = located.compactMap { diagnostic, location -> Diagnostic? in
            // Only the pull request's own paths, which then resolve exactly:
            // a suffix match on a head path could pick another file.
            guard let location, let line = location.line, changes.files[location.path] != nil else { return nil }
            var mapped = diagnostic
            mapped.path = location.path
            mapped.line = line
            return mapped
        }
        return (DiagnosticMatcher.match(mapped, against: changes), located.count { $0.1 == nil })
    }

    /// Whether a path, once the workspace is stripped, names a file in the
    /// checkout at `workspace`. Only a path in plain form is checked: one
    /// that is absolute, or has an empty, `.` or `..` component, isn't the
    /// spelling of a known path even when it names one (`./Foo.swift`), so
    /// it's left to the suffix match.
    private static func existsInCheckout(at workspace: String) -> @Sendable (String) -> Bool {
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
        return { path in
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
    }

    /// A finding at the diagnostic's head location: a failure at or above
    /// `threshold`, and below it a warning for a warning and a message for
    /// a note. Its text is the tool's message, escaped, so nothing in a log
    /// renders as Markdown or HTML, mentions anyone, or links an issue; and
    /// the rule, if any, as a code span.
    static func finding(for diagnostic: MatchedDiagnostic, failingOn threshold: DiagnosticSeverity) -> Finding {
        let severity = DiagnosticSeverity(diagnostic.severity)
        let kind: Finding.Kind = if severity >= threshold {
            .failure
        } else {
            severity == .warning ? .warning : .message
        }
        let message = Markdown.escaped(diagnostic.message)
        let text = switch (message.isEmpty, diagnostic.rule.map(Markdown.codeSpan)) {
        case (_, nil): message
        case (true, let rule?): rule
        case (false, let rule?): "\(message) (\(rule))"
        }
        return Finding(kind: kind, text: text, location: Location(path: diagnostic.path, line: diagnostic.line))
    }

    private static func count(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}
