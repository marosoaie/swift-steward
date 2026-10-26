import Foundation
import GitDiffKit
import PullRequestHosting
@testable import Steward
import Testing

/// The pull request a dry run stands in, sized from the local diff.
@Suite("The placeholder pull request")
struct PlaceholderTests {
    static let signature = Commit.Signature(name: "Ada Lovelace", email: "ada@example.com",
                                            date: Date(timeIntervalSince1970: 0))
    static let headCommit = Commit(sha: Context.stubHead, parents: [Context.stubBase], author: signature,
                                   committer: signature, subject: "Turn a file into a symlink", body: "")

    /// A path deleted and created again, and two that decode alike.
    static let typeChanges: [([UInt8], [UInt8])] = [
        (Array("link".utf8), Array("link".utf8)),
        (Array("a".utf8) + [0xFF], Array("a".utf8) + [0xFE]),
    ]

    @Test("a type change counts once, as GitHub counts it, but two paths that only decode alike count twice",
          arguments: typeChanges)
    func changedFiles(deleted: [UInt8], created: [UInt8]) {
        let changes = GitChanges(
            diff: Diff(diff: Self.diff(deleting: deleted, creating: created)),
            commits: [],
            mergeBase: Context.stubBase,
            head: Context.stubHead
        )
        #expect(changes.diff.files.count == 2)
        #expect(changes.deletedFiles == changes.createdFiles)
        let pullRequest = PullRequest.placeholder(
            for: changes,
            headCommit: Self.headCommit,
            author: "ada",
            base: PullRequest.Branch(name: "main", commit: Context.stubBase, repository: ""),
            head: PullRequest.Branch(name: "feature", commit: Context.stubHead, repository: "")
        )
        #expect(pullRequest.changedFiles == (deleted == created ? 1 : 2))
        #expect(pullRequest.additions == 1)
        #expect(pullRequest.deletions == 0)
    }

    /// An empty file deleted at `old`, and a symlink to `target` created at
    /// `new`, as `git diff` prints a type change.
    static func diff(deleting old: [UInt8], creating new: [UInt8]) -> [UInt8] {
        let lines: [[UInt8]] = [
            Array("diff --git a/".utf8) + old + Array(" b/".utf8) + old,
            Array("deleted file mode 100644".utf8),
            Array("index e69de29..0000000".utf8),
            Array("diff --git a/".utf8) + new + Array(" b/".utf8) + new,
            Array("new file mode 120000".utf8),
            Array("index 0000000..1de5659".utf8),
            Array("--- /dev/null".utf8),
            Array("+++ b/".utf8) + new,
            Array("@@ -0,0 +1 @@".utf8),
            Array("+target".utf8),
            Array("\\ No newline at end of file".utf8),
        ]
        return lines.flatMap { $0 + [UInt8(ascii: "\n")] }
    }
}
