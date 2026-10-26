import GitDiffKit
import PullRequestHosting
import Steward
import Testing

extension Context {
    /// Expects GitHub's own sizes for the pull request, from the payload,
    /// to match the context's diff and commits.
    func expectCountsMatchGitHub(sourceLocation: SourceLocation = #_sourceLocation) {
        let lines = git.diff.files.flatMap { $0.lines }
        #expect(git.commits.count == pullRequest.commits, sourceLocation: sourceLocation)
        #expect(git.diff.files.count == pullRequest.changedFiles, sourceLocation: sourceLocation)
        #expect(lines.count { $0.info.kind == .addition } == pullRequest.additions, sourceLocation: sourceLocation)
        #expect(lines.count { $0.info.kind == .deletion } == pullRequest.deletions, sourceLocation: sourceLocation)
    }
}
