import Steward

/// The Dangerfile the end-to-end tests run on real pull requests: every
/// kind of finding, with a location and without, a failure past a size,
/// a rule that throws when the title asks it to, and the built-in
/// diagnostics rule when the environment names reports for it.
@main
struct FixtureChecks: Dangerfile {
    /// A title with this in it makes the "Fixture marker" rule throw.
    static let throwMarker = "[steward-fixture: throw]"
    /// A pull request that adds more lines fails.
    static let addedLineLimit = 1000

    static var rules: [Rule] {
        Rule("Size") { context in
            let pullRequest = context.pullRequest
            return [.message("""
                Changes \(pullRequest.changedFiles) files (+\(pullRequest.additions) −\(pullRequest.deletions)) \
                in \(pullRequest.commits) commits
                """)]
        }
        Rule("New files") { context in
            context.git.createdFiles.map { .message("New file", at: Location(path: $0)) }
        }
        Rule("Deleted files") { context in
            context.git.deletedFiles.map { .warning("Deleted", at: Location(path: $0)) }
        }
        Rule("First edits") { context in
            context.git.modifiedFiles.filter { $0.hasSuffix(".swift") }.compactMap { path in
                let added = context.git.file(at: path)?.lines.first { $0.info.kind == .addition }
                return added?.info.newNumber.map { .message("First added line", at: Location(path: path, line: $0)) }
            }
        }
        Rule("Large pull request") { context in
            guard context.pullRequest.additions > addedLineLimit else { return [] }
            return [.failure("Adds more than \(addedLineLimit) lines")]
        }
        Rule("Commits") { context in
            context.git.commits.isEmpty ? [] : [.markdown(context.git.commits.map { commit in
                "- `\(commit.sha.prefix(7))` \(commit.subject)"
            }.joined(separator: "\n"))]
        }
        Rule("Fixture marker") { context in
            guard context.pullRequest.title.contains(throwMarker) else { return [] }
            throw MarkerError()
        }
        if let diagnosticSources {
            Rule.diagnosticsOnChangedLines(in: diagnosticSources)
        }
    }
}
