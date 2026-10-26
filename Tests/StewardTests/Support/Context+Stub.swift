import Foundation
import GitDiffKit
import PullRequestHosting
import Steward

extension Context {
    static let stubHead = "4c95447a3d2f8e1b0c9d7e6f5a4b3c2d1e0f9a8b"
    static let stubBase = "1ca8c39b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e7d"

    /// A context for unit tests: pull request #7 of `o/r`, from `base` to
    /// `head`, with `diff` as its changes and nothing read from git.
    static func stub(
        diff: String = "",
        commits: [Commit] = [],
        title: String = "Add a feature",
        labels: [String] = []
    ) -> Context {
        Context(
            pullRequest: PullRequest(
                number: 7,
                title: title,
                body: "",
                author: "ada",
                state: .open,
                isDraft: false,
                base: PullRequest.Branch(name: "main", commit: stubBase, repository: "o/r"),
                head: PullRequest.Branch(name: "feature", commit: stubHead, repository: "o/r"),
                labels: labels,
                webURL: "https://github.com/o/r/pull/7",
                additions: 0,
                deletions: 0,
                changedFiles: 0,
                commits: commits.count
            ),
            git: GitChanges(diff: Diff(diff: diff), commits: commits, mergeBase: stubBase, head: stubHead),
            run: Run(
                mode: .actions,
                workspace: "/workspace",
                builtCommit: stubHead,
                lineMap: .identity,
                apiURL: URL(string: "https://api.github.com")!,
                serverURL: URL(string: "https://github.com")!
            )
        )
    }
}
