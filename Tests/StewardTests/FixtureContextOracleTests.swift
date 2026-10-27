import Foundation
import GitDiffKit
@testable import Steward
import StewardTesting
import Testing

/// StewardTesting's `Context.fixture(diff:)` against the context a real
/// run builds for the same changes: on this project's merged pull
/// requests, and on two large ranges of public repositories, with the
/// diff git writes for Steward and the one GitHub's compare page serves.
///
/// Clones and downloads into the fixture cache once; set
/// `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS` to skip. Serialized, as the
/// mirrors are shared.
@Suite(
    "Fixture contexts against real runs",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
)
struct FixtureContextOracleTests {
    /// A range of a public repository, between two tags.
    enum Range: String, CaseIterable, Sendable {
        case swiftArgumentParser = "apple/swift-argument-parser 1.0.0...1.5.0"
        case redis = "redis/redis 7.0.0...7.2.0"

        /// `owner/name`.
        var repository: String {
            String(rawValue.prefix { $0 != " " })
        }

        var tags: (base: String, head: String) {
            let range = rawValue.drop { $0 != " " }.dropFirst()
                .split(separator: "...", omittingEmptySubsequences: false)
            return (String(range.first ?? ""), String(range.last ?? ""))
        }
    }

    @Test("a fixture from the diff a run reads has that run's git data, and GitHub's sizes", arguments: [
        "swift-steward-17", "swift-steward-20", "swift-steward-22", "swift-steward-24", "swift-steward-26",
        "git-diff-parser-1", "git-diff-parser-2", "git-diff-parser-5", "git-diff-parser-8",
    ])
    func mergedPullRequest(name: String) async throws {
        let payload = try EventPayload.pullRequest(name)
        let base = try payload.sha(of: "base")
        let head = try payload.sha(of: "head")
        let merge = try #require(payload.pullRequestField("merge_commit_sha") as? String)
        let mirror = try RepositoryMirror.local(RealPullRequestTests.repository(of: name), having: [base, head, merge])
        let real = try await Self.context(of: payload, in: mirror, built: merge)
        let text = try await Self.diffText(of: real, in: mirror)

        // On the real branches, the fixture's git data is the run's.
        let fixture = try Context.fixture(
            diff: text,
            pullRequest: .fixture(base: real.pullRequest.base, head: real.pullRequest.head),
            commits: real.git.commits,
            workspace: mirror.path
        )
        Self.expectSameGit(fixture.git, real.git)

        // Without a pull request, the fixture sizes the default one from
        // the diff and the commits; the real run's sizes are GitHub's,
        // from the payload.
        let sized = try Context.fixture(diff: text, commits: real.git.commits).pullRequest
        #expect(sized.additions == real.pullRequest.additions)
        #expect(sized.deletions == real.pullRequest.deletions)
        #expect(sized.changedFiles == real.pullRequest.changedFiles)
        #expect(sized.commits == real.pullRequest.commits)

        // Given the real pull request, the fixture is the real context,
        // but for the merge base and the built commit: a fixture's are the
        // pull request's base and head.
        var given = try Context.fixture(
            diff: text,
            pullRequest: real.pullRequest,
            commits: real.git.commits,
            workspace: mirror.path
        )
        given.git.mergeBase = real.git.mergeBase
        given.run.builtCommit = real.run.builtCommit
        given.run.lineMap = real.run.lineMap
        let isReal = given == real
        #expect(isReal, "the fixture differs from the real context beyond the merge base and the built commit")
    }

    @Test("a fixture from git's diff, or GitHub's, has the files and lines of a real run's context",
          arguments: Range.allCases)
    func publicRange(range: Range) async throws {
        let (baseTag, headTag) = range.tags
        let mirror = try RepositoryMirror.upstream(range.repository, tags: [baseTag, headTag])
        let git = Git(directory: mirror.path)
        let base = try #require(try await git.commit(named: "refs/tags/\(baseTag)^{commit}"))
        let head = try #require(try await git.commit(named: "refs/tags/\(headTag)^{commit}"))
        let payload = try EventPayload.pullRequest("swift-steward-26").setting(base: base, head: head)
        let real = try await Self.context(of: payload, in: mirror, built: head)
        #expect(real.git.diff.files.count > 50, "\(real.git.diff.files.count) files")

        let fromGit = try Context.fixture(
            diff: try await Self.diffText(of: real, in: mirror),
            pullRequest: .fixture(base: real.pullRequest.base, head: real.pullRequest.head),
            commits: real.git.commits
        )
        Self.expectSameGit(fromGit.git, real.git)

        // GitHub abbreviates blob ids to 9 digits and fills in hunk
        // headings from the repository's attributes; the rest is git's.
        let compare = try await RepositoryMirror.compareDiff(of: range.repository, from: baseTag, to: headTag)
        let fromGitHub = try Context.fixture(diff: compare)
        Self.expectSameFilesAndLines(fromGitHub.git, real.git)
    }

    /// The context a run in Actions builds for `payload`'s pull request,
    /// in `mirror`, with `built` as the commit Actions checked out.
    private static func context(of payload: EventPayload, in mirror: URL, built: String) async throws -> Context {
        let event = try payload.writeTemporary()
        defer { try? FileManager.default.removeItem(at: event) }
        return try await Context.actions(environment: [
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_EVENT_PATH": event.path,
            "GITHUB_WORKSPACE": mirror.path,
            "GITHUB_SHA": built,
        ])
    }

    /// The text of the diff a run reads for `context`: git's, with the
    /// options Steward pins.
    private static func diffText(of context: Context, in mirror: URL) async throws -> String {
        let output = try await Git(directory: mirror.path).output(
            Git.diffConfiguration + ["diff"] + Git.diffOptions
                + ["--unified=3", context.git.mergeBase, context.git.head, "--"]
        )
        return String(decoding: output, as: UTF8.self)
    }

    /// Expects the same diff, commits, and head, comparing without
    /// printing either side: a diff can be megabytes long, and a line
    /// that long stalls GitHub's log viewer.
    private static func expectSameGit(
        _ fixture: GitChanges,
        _ real: GitChanges,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let isSameDiff = fixture.diff == real.diff
        #expect(isSameDiff, "the diffs differ", sourceLocation: sourceLocation)
        expectSameFilesAndLines(fixture, real, sourceLocation: sourceLocation)
        let isSameCommits = fixture.commits == real.commits
        #expect(isSameCommits, "the commits differ", sourceLocation: sourceLocation)
        #expect(fixture.head == real.head, sourceLocation: sourceLocation)
    }

    /// Expects the same files, in order, with the same changes, paths,
    /// modes, and lines, and the same file lists, naming the first file
    /// that differs.
    private static func expectSameFilesAndLines(
        _ fixture: GitChanges,
        _ real: GitChanges,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(fixture.diff.damage.isEmpty, sourceLocation: sourceLocation)
        #expect(fixture.diff.files.count == real.diff.files.count, sourceLocation: sourceLocation)
        let firstDifference = zip(fixture.diff.files, real.diff.files).first { pair in
            let (fixture, real) = (pair.0.header, pair.1.header)
            return fixture.change != real.change || fixture.oldPath != real.oldPath || fixture.newPath != real.newPath
                || fixture.oldMode != real.oldMode || fixture.newMode != real.newMode
                || fixture.isBinary != real.isBinary || pair.0.lines != pair.1.lines
        }
        let path = firstDifference.flatMap { $0.1.header.newPath ?? $0.1.header.oldPath }?.string
        #expect(path == nil, "the first file that differs", sourceLocation: sourceLocation)
        let lists = [
            fixture.createdFiles == real.createdFiles,
            fixture.modifiedFiles == real.modifiedFiles,
            fixture.deletedFiles == real.deletedFiles,
            fixture.renamedFiles == real.renamedFiles,
        ]
        #expect(lists == [true, true, true, true], "created, modified, deleted, renamed",
                sourceLocation: sourceLocation)
    }
}
