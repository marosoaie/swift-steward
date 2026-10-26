import Foundation
@testable import Steward

/// What the fixture Dangerfile (`FixtureChecks`) should find in a pull
/// request, worked out from git's raw output, the commits' raw objects, and
/// GitHub's counts, never from the context Steward builds.
struct FixtureExpectation {
    /// GitHub's sizes of the pull request.
    struct Counts {
        var changedFiles: Int
        var additions: Int
        var deletions: Int
        var commits: Int

        /// The counts in a `pull_request` payload, or a `pulls/get` answer
        /// made one.
        init(payload: EventPayload) throws {
            let values = try ["changed_files", "additions", "deletions", "commits"].map { key in
                guard let value = payload.pullRequestField(key) as? Int else {
                    throw FixtureError("the payload has no pull_request.\(key)")
                }
                return value
            }
            changedFiles = values[0]
            additions = values[1]
            deletions = values[2]
            commits = values[3]
        }
    }

    /// The failure the "Fixture marker" rule's error becomes.
    static let thrownRule = "Rule “Fixture marker” failed: the title asks this rule to throw"

    /// The findings, in rule order, each with its rule's name.
    var findings: [Finding]
    /// The paths the head commit doesn't have, which the summary shows
    /// without a link.
    var unlinkedPaths: Set<String>

    /// The status the run should exit with.
    var status: Int32 { findings.contains { $0.kind == .failure } ? 1 : 0 }

    /// The expectation for the pull request from `base` to `head`, whose
    /// commits are `commits`, oldest first, and whose title asks the
    /// fixture's last rule to throw when `asksToThrow` is set.
    init(
        oracle: GitOracle,
        base: String,
        head: String,
        counts: Counts,
        commits: [String],
        asksToThrow: Bool = false
    ) throws {
        let mergeBase = try oracle.text(["merge-base", base, head])
        let entries = try oracle.rawStatus(from: mergeBase, to: head)
        // A type change (T) is a deletion and a creation of one path.
        let created = entries.filter { "AT".contains($0.status) }.map { $0.paths[0] }
        let deleted = entries.filter { "DT".contains($0.status) }.map { $0.paths[0] }
        let edited = entries.filter { "MR".contains($0.status) }
        let firstEdits = try edited.filter { $0.paths[$0.paths.count - 1].hasSuffix(".swift") }.compactMap { entry in
            try Self.firstAddedLine(of: entry.paths, from: mergeBase, to: head, oracle: oracle).map { line in
                Finding.message("First added line", at: Location(path: entry.paths[entry.paths.count - 1], line: line))
            }
        }
        let subjects = try commits.map { "- `\($0.prefix(7))` \(try oracle.rawCommit($0).subject)" }
        let size = """
            Changes \(counts.changedFiles) files (+\(counts.additions) −\(counts.deletions)) \
            in \(counts.commits) commits
            """
        let ruleFindings: [(String, [Finding])] = [
            ("Size", [.message(size)]),
            ("New files", created.map { .message("New file", at: Location(path: $0)) }),
            ("Deleted files", deleted.map { .warning("Deleted", at: Location(path: $0)) }),
            ("First edits", firstEdits),
            ("Large pull request", counts.additions > 1000 ? [.failure("Adds more than 1000 lines")] : []),
            ("Commits", subjects.isEmpty ? [] : [.markdown(subjects.joined(separator: "\n"))]),
            ("Fixture marker", asksToThrow ? [.failure(Self.thrownRule)] : []),
        ]
        findings = ruleFindings.flatMap { rule, findings in
            findings.map { finding in
                var finding = finding
                finding.rule = rule
                return finding
            }
        }
        let renames = entries.filter { $0.status == "R" }
        unlinkedPaths = Set(entries.filter { $0.status == "D" }.map { $0.paths[0] } + renames.map { $0.paths[0] })
            .subtracting(created + edited.map { $0.paths[$0.paths.count - 1] })
    }

    /// The report a run should write.
    func report(repository: String, pullRequest: Int, head: String) -> Report {
        Report(
            repository: repository,
            pullRequest: pullRequest,
            headCommit: head,
            findings: findings,
            generator: "Steward"
        )
    }

    /// The first line `git diff --unified=0` adds to the file at `paths`
    /// (two for a rename), from its hunk headers, `@@ -a,b +c,d @@` with
    /// `d` 1 when left out; nil when it adds none.
    private static func firstAddedLine(
        of paths: [String],
        from old: String,
        to new: String,
        oracle: GitOracle
    ) throws -> Int? {
        let patch = try oracle.text(
            ["--literal-pathspecs"] + Git.diffConfiguration + ["diff"] + Git.diffOptions
                + ["--unified=0", old, new, "--"] + paths
        )
        return patch.split(separator: "\n").lazy.filter { $0.hasPrefix("@@ -") }.compactMap { header -> Int? in
            let words = header.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count > 2, words[2].hasPrefix("+") else { return nil }
            let numbers = words[2].dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(numbers[0]) else { return nil }
            let count = numbers.count > 1 ? Int(numbers[1]) : 1
            return count == 0 ? nil : start
        }.first
    }
}
