import Foundation
@testable import Steward
import Testing

extension RealPullRequestTests {
    /// Every path a merged pull request touched, read at its head and at
    /// its merge base: through the run's context one by one, and through
    /// the reader all in one call.
    @Test("every file a merged pull request changed reads as git show prints it, at the head and the merge base",
          // The largest of each repository's recorded pull requests, and
          // a small one: some eighty paths, each shown and read at both sides.
          arguments: ["swift-steward-22", "swift-steward-26", "git-diff-parser-8"])
    func files(name: String) async throws {
        let payload = try EventPayload.pullRequest(name)
        let base = try payload.sha(of: "base")
        let head = try payload.sha(of: "head")
        let merge = try #require(payload.pullRequestField("merge_commit_sha") as? String)
        let mirror = try RepositoryMirror.local(Self.repository(of: name), having: [base, head, merge])
        let event = try payload.writeTemporary()
        defer { try? FileManager.default.removeItem(at: event) }
        let context = try await Context.actions(environment: [
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_EVENT_PATH": event.path,
            "GITHUB_WORKSPACE": mirror.path,
            "GITHUB_SHA": merge,
        ])
        #expect(context.localRepository is GitRepository)
        let oracle = GitOracle(directory: mirror.path)
        let git = context.git
        let paths = Array(Set(
            git.createdFiles + git.modifiedFiles + git.deletedFiles + git.renamedFiles.flatMap { [$0.from, $0.to] }
        )).sorted()
        #expect(!paths.isEmpty)
        let reader = GitRepository(git: Git(directory: mirror.path))

        try await [(Context.Side.head, git.head), (.mergeBase, git.mergeBase)].asyncForEach { side, commit in
            let modes = try oracle.modes(at: commit)
            let expected = try paths.map { path in
                try oracle.show(path, at: commit).map { shown in
                    modes[path]?.hasPrefix("100") == true ? FileContents.bytes(shown) : .notRegularFile
                } ?? .noSuchFile
            }
            #expect(expected.contains { if case .bytes = $0 { true } else { false } })
            #expect(try await reader.contents(ofFilesAt: paths, in: commit, limit: .max) == expected)
            try await zip(paths, expected).asyncForEach { path, whole in
                let read = try await context.contents(ofFileAt: path, at: side)
                let limited = if case .bytes(let bytes) = whole, bytes.count > FileContents.defaultLimit {
                    FileContents.tooLarge(size: bytes.count)
                } else {
                    whole
                }
                #expect(read == limited, "\(name): \(path) at \(side)")
            }
        }
    }
}
