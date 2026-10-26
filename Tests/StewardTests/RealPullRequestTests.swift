import Foundation
import GitDiffKit
import PullRequestHosting
@testable import Steward
import Testing

/// Contexts built from real payloads and real checkouts of this project's
/// two repositories, checked against git and against what GitHub said.
///
/// Clones the repositories from github.com into the fixture cache once;
/// set `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS` to skip. Serialized, so two
/// tests never fetch into the same mirror at once.
@Suite(
    "Real pull requests",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
)
struct RealPullRequestTests {
    /// What `pulls/get` and `pulls/N/commits` answered for merged pull
    /// requests, recorded on 2026-10-26: renames, deletions, merges of main
    /// into the branch, a base that moved, and one large diff each.
    @Test("a merged pull request's context matches git, and GitHub's counts", arguments: [
        "swift-steward-17", "swift-steward-20", "swift-steward-22", "swift-steward-24", "swift-steward-26",
        "git-diff-parser-1", "git-diff-parser-2", "git-diff-parser-5", "git-diff-parser-8",
    ])
    func merged(name: String) async throws {
        let payload = try EventPayload.pullRequest(name)
        let base = try payload.sha(of: "base")
        let head = try payload.sha(of: "head")
        let merge = try #require(payload.pullRequestField("merge_commit_sha") as? String)
        let mirror = try RepositoryMirror.local(Self.repository(of: name), having: [base, head, merge])
        let event = try payload.writeTemporary()
        defer { try? FileManager.default.removeItem(at: event) }

        // The merge commit stands in for the test merge Actions builds.
        let context = try await Context.actions(environment: [
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_EVENT_PATH": event.path,
            "GITHUB_WORKSPACE": mirror.path,
            "GITHUB_SHA": merge,
        ])
        let oracle = GitOracle(directory: mirror.path)
        try oracle.verify(context.git, base: base)
        try oracle.verify(context.run.lineMap, head: head, built: merge)
        #expect(context.git.commits.map(\.sha) == (try Self.recordedCommits(name)))
        context.expectCountsMatchGitHub()
    }

    @Test("the payloads Actions wrote for swift-steward#21 build its context", arguments: [
        "pull-request-event.opened", "pull-request-event.synchronize",
    ])
    func recordedEvent(name: String) async throws {
        let payload = try EventPayload.recorded(name)
        let base = try payload.sha(of: "base")
        let head = try payload.sha(of: "head")
        let mirror = try RepositoryMirror.local("swift-steward", having: [base, head])
        let event = try payload.writeTemporary()
        defer { try? FileManager.default.removeItem(at: event) }

        // The test merge Actions built is gone with the closed pull request.
        let context = try await Context.actions(environment: [
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_EVENT_PATH": event.path,
            "GITHUB_WORKSPACE": mirror.path,
            "GITHUB_SHA": head,
        ])
        try GitOracle(directory: mirror.path).verify(context.git, base: base)
        #expect(context.pullRequest.number == 21)
        #expect(context.pullRequest.isDraft)
        #expect(context.run.lineMap == .identity)
        context.expectCountsMatchGitHub()
    }

    // git log would read 37 commits with the cut at the base, and 25 with
    // it at the base's second parent, which no commit of the range is.
    @Test("git-diff-parser#5 with a shallow cut on its base's side is refused, not read as more than 16 commits",
          arguments: ["the base", "its second parent"])
    func shallowBase(cutAt position: String) async throws {
        let payload = try EventPayload.pullRequest("git-diff-parser-5")
        let base = try payload.sha(of: "base")
        let head = try payload.sha(of: "head")
        let mirror = try RepositoryMirror.local("git-diff-parser", having: [base, head])
        let clone = try TestRepository(cloning: mirror.path, options: ["--bare", "--shared"])
        defer { clone.remove() }
        let cut = position == "the base" ? base : try clone.git(["rev-parse", "\(base)^2"])
        // As a depth-limited fetch of the base can leave it; bare, so the
        // repository's own folder.
        try clone.write("\(cut)\n", to: "shallow")
        try payload.write(to: clone.eventURL)
        let full = try await Context.actions(environment: [
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_EVENT_PATH": clone.eventURL.path,
            "GITHUB_WORKSPACE": mirror.path,
            "GITHUB_SHA": head,
        ])
        #expect(full.git.commits.count == 16)

        let error = await #expect(throws: ContextError.self) {
            try await Context.actions(environment: [
                "GITHUB_EVENT_NAME": "pull_request",
                "GITHUB_EVENT_PATH": clone.eventURL.path,
                "GITHUB_WORKSPACE": clone.path,
                "GITHUB_SHA": head,
            ])
        }
        guard case .truncatedHistory(base, head, _)? = error else {
            Issue.record("expected truncatedHistory, got \(String(describing: error))")
            return
        }
    }

    /// docs/danger.md, section 3: had git-diff-parser#2 landed before #1,
    /// the merge tree CI built would have shifted #1's AGENTS.md lines by
    /// five.
    @Test("git-diff-parser#1 replayed onto #2: built line 96 of AGENTS.md maps back to head line 91")
    func mergeTreeReplay() async throws {
        let forkPoint = "ce8bbbf8d2d37860a11f252f38b0412984ea007a"
        let firstHead = "b81007f5d6c7bef0258e2a1192617b5990193620"
        let secondHead = "ce6e916eccff315f73daff1a9b3025e250d3ab24"
        let mirror = try RepositoryMirror.local("git-diff-parser", having: [forkPoint, firstHead, secondHead])
        let clone = try TestRepository(cloning: mirror.path, options: ["--bare", "--shared"])
        defer { clone.remove() }
        let tree = try clone.git(["merge-tree", "--write-tree", secondHead, firstHead])
        let built = try clone.git(
            ["commit-tree", tree, "-p", secondHead, "-p", firstHead, "-m", "Replay git-diff-parser#1 onto #2"],
            environment: ["GIT_AUTHOR_DATE": "@1761400000 +0000", "GIT_COMMITTER_DATE": "@1761400000 +0000"]
        )
        // As if #2 had landed first: #1's base is #2's head.
        try EventPayload.pullRequest("git-diff-parser-1").setting(base: secondHead).write(to: clone.eventURL)
        let context = try await Context.actions(environment: [
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_EVENT_PATH": clone.eventURL.path,
            "GITHUB_WORKSPACE": clone.path,
            "GITHUB_SHA": built,
        ])

        #expect(context.git.mergeBase == forkPoint)
        // The doc's hunks are git's at -U0; the context's diff has context.
        let reviewed = try clone.git(["diff", "-U0", "--no-color", "\(forkPoint)...\(firstHead)", "--", "AGENTS.md"])
        let tested = try clone.git(["diff", "-U0", "--no-color", secondHead, built, "--", "AGENTS.md"])
        #expect(reviewed.contains("@@ -91,3 +91,8 @@"))
        #expect(tested.contains("@@ -96,3 +96,8 @@"))
        let added = context.git.file(at: "AGENTS.md")?.lines.first { $0.info.kind == .addition }
        #expect(added?.info.newNumber == 91)
        let mapped = context.run.lineMap.headLocation(ofLine: 96, inFile: "AGENTS.md")
        #expect(mapped == Location(path: "AGENTS.md", line: 91))
        let oracle = GitOracle(directory: clone.path)
        let headLine = try #require(try oracle.lines(of: "AGENTS.md", at: firstHead)?[90])
        #expect(String(decoding: headLine, as: UTF8.self).hasPrefix("**Doc comments on public API"))
        try oracle.verify(context.git, base: secondHead)
        try oracle.verify(context.run.lineMap, head: firstHead, built: built)
    }

    // Another suite's tests can ask for a mirror at the same time; the
    // race itself can't be produced on demand, so this runs the path.
    @Test("mirror refreshes asked for in parallel take turns, each fetch finishing on its own")
    func parallelRefreshes() async {
        let absent = String(repeating: "0", count: 39) + "1"
        let errors = await withTaskGroup(of: String.self) { group in
            (0..<3).forEach { _ in
                group.addTask {
                    do {
                        _ = try RepositoryMirror.local("git-diff-parser", having: [absent])
                        return "found \(absent)"
                    } catch {
                        return String(describing: error)
                    }
                }
            }
            return await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(errors.count == 3)
        #expect(errors.allSatisfy { $0.contains("lacks \(absent) even after a fetch") }, "\(errors)")
    }

    /// `swift-steward-17` → `swift-steward`.
    static func repository(of name: String) -> String {
        name.split(separator: "-").dropLast().joined(separator: "-")
    }

    static func recordedCommits(_ name: String) throws -> [String] {
        let url = Bundle.module.url(forResource: name, withExtension: "commits", subdirectory: "Fixtures/pulls")
        guard let url else {
            throw FixtureError("no fixture Fixtures/pulls/\(name).commits")
        }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }
}
