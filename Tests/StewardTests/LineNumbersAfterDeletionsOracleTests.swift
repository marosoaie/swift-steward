import Foundation
import GitDiffKit
@testable import Steward
import StewardTesting
import Testing

/// `GitChanges.lineNumbersAfterDeletions` against `git diff --unified=0` on real
/// pull requests: each hunk that deletes lines gives `newStart + 1` when
/// it adds none, and `newStart` when it adds some.
///
/// Steward reads its diff with three lines of context, and git trims the
/// end two files share only when there's none, so it can place, split or
/// join a run differently among repeated lines at `-U0`
/// (swift-steward#68). The test tells that from a wrong answer by reading
/// the lines after deletions off each diff's alignment, the old lines it
/// deletes and the new lines it adds, by a rule of its own that `-U0`'s
/// hunks confirm on every file. Steward's answer is its own diff's
/// alignment's; where it isn't `-U0`'s, the two diffs still make the same
/// change: by each line's text, what one deletes less what it adds is
/// what the other does, as both are the base less the head.
///
/// Clones and downloads into the fixture cache once; set
/// `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS` to skip. Serialized, as the
/// mirrors are shared.
@Suite(
    "Lines after deletions against git",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
)
struct LineNumbersAfterDeletionsOracleTests {
    @Test("on this project's merged pull requests, the lines after deletions are git's", arguments: [
        "swift-steward-17", "swift-steward-20", "swift-steward-22", "swift-steward-24", "swift-steward-26",
        "git-diff-parser-1", "git-diff-parser-2", "git-diff-parser-5", "git-diff-parser-8",
    ])
    func mergedPullRequest(name: String) async throws {
        let payload = try EventPayload.pullRequest(name)
        let base = try payload.sha(of: "base")
        let head = try payload.sha(of: "head")
        let merge = try #require(payload.pullRequestField("merge_commit_sha") as? String)
        let mirror = try RepositoryMirror.local(RealPullRequestTests.repository(of: name), having: [base, head, merge])
        let real = try await FixtureContextOracleTests.context(of: payload, in: mirror, built: merge)
        let tally = try await Self.check(real, in: mirror)
        #expect(tally.deletions > 0)
        #expect(tally.realigned.isEmpty)
    }

    @Test("on two large ranges of public repositories, the lines after deletions are git's",
          arguments: FixtureContextOracleTests.Range.allCases)
    func publicRange(range: FixtureContextOracleTests.Range) async throws {
        let (baseTag, headTag) = range.tags
        let mirror = try RepositoryMirror.upstream(range.repository, tags: [baseTag, headTag])
        let git = Git(directory: mirror.path)
        let base = try #require(try await git.commit(named: "refs/tags/\(baseTag)^{commit}"))
        let head = try #require(try await git.commit(named: "refs/tags/\(headTag)^{commit}"))
        let payload = try EventPayload.pullRequest("swift-steward-26").setting(base: base, head: head)
        let real = try await FixtureContextOracleTests.context(of: payload, in: mirror, built: head)
        let tally = try await Self.check(real, in: mirror)
        #expect(tally.deletions > 500, "\(tally.deletions) deletions")
        // Git's own alignments: it places, splits or joins runs among
        // repeated lines differently at -U0 than with context.
        let realigned: [String] = switch range {
        case .swiftArgumentParser: []
        case .redis: ["src/sentinel.c", "tests/unit/pause.tcl"]
        }
        #expect(tally.realigned.map(\.path) == realigned)
    }

    @Test("where git aligns a repeated line differently without context, the lines are the context diff's")
    func repeatedLine() async throws {
        // The commits LocalRepositoryLineMapTests pins: git deletes and
        // adds blank lines of `.github/workflows/pr.yml` at other places
        // at -U0 than with context.
        let base = "b000024df6c37475658a4bb3a374a5752cbf190b"
        let head = "4440e09b0c87323a0d53223568b0e1cb3a57be7e"
        let mirror = try RepositoryMirror.local("swift-steward", having: [base, head])
        let payload = try EventPayload.pullRequest("swift-steward-26").setting(base: base, head: head)
        let real = try await FixtureContextOracleTests.context(of: payload, in: mirror, built: head)
        let tally = try await Self.check(real, in: mirror)
        // At -U0 git keeps a blank line above the run of deleted lines and
        // deletes one below it; with context, the other way round, so the
        // run ends further down.
        #expect(tally.realigned == [
            Realignment(path: ".github/workflows/pr.yml", withContext: [86], withoutContext: [77]),
        ])
    }

    /// What `check` found.
    struct Tally: Equatable {
        /// How many hunks of git's `-U0` diff delete lines.
        var deletions = 0
        /// The files whose `-U0` alignment isn't the context diff's, and
        /// whose lines after deletions differ for it, by path.
        var realigned: [Realignment] = []
    }

    /// A file whose lines after deletions differ between git's diff with
    /// context and its diff without: the lines only one of them gives.
    struct Realignment: Equatable {
        var path: String
        var withContext: [Int]
        var withoutContext: [Int]
    }

    /// Expects `context`'s lines after deletions to be those of its diff's
    /// alignment, and `git diff --unified=0`'s where the alignments agree;
    /// the rule they're read by to be `-U0`'s hunks' on every file; and
    /// where Steward's answer isn't `-U0`'s, the two diffs to make the same
    /// change.
    static func check(_ context: Context, in mirror: URL) async throws -> Tally {
        let text = try await FixtureContextOracleTests.diffText(of: context, in: mirror, contextLines: 0)
        let withoutContext = try Self.headFiles(of: Context.fixture(diff: text).git.diff)
        let withContext = Self.headFiles(of: context.git.diff)
        #expect(Set(withContext.keys) == Set(withoutContext.keys))
        let steward = context.git.lineNumbersAfterDeletions
        return withoutContext.sorted { $0.key < $1.key }.reduce(into: Tally()) { tally, entry in
            let (path, file) = entry
            let hunks = Set(file.hunks.filter { $0.header.oldCount > 0 }.map { hunk in
                hunk.header.newCount == 0 ? hunk.header.newStart + 1 : hunk.header.newStart
            })
            let gits = DiffAlignment(of: file)
            #expect(gits.lineNumbersAfterDeletions == hunks, "the alignment's rule isn't git's in \(path)")
            tally.deletions += file.hunks.count { $0.header.oldCount > 0 }
            guard let read = withContext[path] else { return }
            let stewards = DiffAlignment(of: read)
            let lines = Set(steward.files[path]?.allLineNumbers ?? [])
            #expect(lines == stewards.lineNumbersAfterDeletions, "\(path)")
            guard lines != hunks else { return }
            #expect(stewards.change == gits.change, "\(path): another change")
            tally.realigned.append(Realignment(
                path: path,
                withContext: lines.subtracting(hunks).sorted(),
                withoutContext: hunks.subtracting(lines).sorted()
            ))
        }
    }

    /// The files of `diff` that are at the head, by path.
    static func headFiles(of diff: Diff) -> [String: DiffFile] {
        Dictionary(diff.files.compactMap { file in
            file.header.change == .deleted ? nil : file.header.newPath.map { ($0.string, file) }
        }) { first, _ in first }
    }
}

/// How a diff aligns a file: the old lines it deletes and the new lines
/// it adds.
struct DiffAlignment {
    /// The deleted lines' numbers at the base, ascending.
    var deleted: [Int] = []
    /// The added lines' numbers at the head, ascending.
    var added: [Int] = []
    /// By each line's text, how many more times the diff deletes it than
    /// adds it, leaving out the text it deletes as often as it adds: the
    /// base less the head, the same for any diff of the two files, however
    /// it aligns them.
    var change: [[UInt8]: Int] = [:]

    init(of file: DiffFile) {
        file.lines.forEach { line in
            switch line.info.kind {
            case .deletion:
                deleted.append(line.info.oldNumber ?? 0)
                change[Array(line.content), default: 0] += 1
            case .addition:
                added.append(line.info.newNumber ?? 0)
                change[Array(line.content), default: 0] -= 1
            case .context: break
            }
        }
        change = change.filter { $0.value != 0 }
    }

    /// The head line after each run of deleted lines. A run that
    /// starts at base line `d` keeps the `k = d - 1 - (deletions
    /// before it)` lines above it, and git writes a gap's deletions
    /// before its additions, so the line after it is one past the
    /// head's `k`th kept line: `k` plus the added lines up to there.
    var lineNumbersAfterDeletions: Set<Int> {
        let runs = deleted.indices.filter { $0 == 0 || deleted[$0 - 1] != deleted[$0] - 1 }
        // Runs and kept lines both ascend, so one pass over `added`.
        let state = runs.reduce(into: (consumed: 0, lines: Set<Int>())) { state, index in
            var line = deleted[index] - 1 - index + state.consumed
            while state.consumed < added.count, added[state.consumed] <= line {
                state.consumed += 1
                line += 1
            }
            state.lines.insert(line + 1)
        }
        return state.lines
    }
}
