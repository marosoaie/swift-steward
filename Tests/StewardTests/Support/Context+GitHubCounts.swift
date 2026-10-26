import GitDiffKit
import PullRequestHosting
import Steward
import Testing

extension Context {
    /// Expects GitHub's own sizes for the pull request, from the payload,
    /// to match the context's diff and commits.
    func expectCountsMatchGitHub(sourceLocation: SourceLocation = #_sourceLocation) {
        let lines = git.diff.files.flatMap { $0.lines }
        // A type change (a file turned into a symlink, say) is a deletion
        // and a creation of one path, in git's patch and in GitHub's file
        // list, but GitHub counts it once: fastlane/fastlane#7479 lists 8
        // files and says 7 changed.
        let typeChanges = Set(git.deletedFiles).intersection(git.createdFiles).count
        #expect(git.commits.count == pullRequest.commits, sourceLocation: sourceLocation)
        #expect(git.diff.files.count - typeChanges == pullRequest.changedFiles, sourceLocation: sourceLocation)
        #expect(lines.count { $0.info.kind == .addition } == pullRequest.additions, sourceLocation: sourceLocation)
        #expect(lines.count { $0.info.kind == .deletion } == pullRequest.deletions, sourceLocation: sourceLocation)
    }
}
