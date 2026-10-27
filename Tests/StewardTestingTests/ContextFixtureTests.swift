import Foundation
import StewardTesting
import Testing

@Suite("Context.fixture")
struct ContextFixtureTests {
    @Test("the diff is parsed into the model a real run's parser builds")
    func parsesTheDiff() throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        #expect(context.git.diff == Diff(diff: SampleDiff.mixed))
        #expect(context.git.diff.damage.isEmpty)
        #expect(context.git.createdFiles == ["Sources/New.swift"])
        #expect(context.git.deletedFiles == ["Docs/Old.md"])
        #expect(context.git.modifiedFiles == ["Sources/App.swift", "Sources/After.swift"])
        #expect(context.git.renamedFiles == [.init(from: "Sources/Before.swift", to: "Sources/After.swift")])
        let added = context.git.file(at: "Sources/App.swift")?.lines.filter { $0.info.kind == .addition }
        #expect(added?.compactMap(\.info.newNumber) == [2])
    }

    @Test("without a pull request, the default one is sized as GitHub sizes the diff")
    func sizesTheDefaultPullRequest() throws {
        let context = try Context.fixture(diff: SampleDiff.mixed)
        var expected = PullRequest.fixture()
        expected.additions = 3
        expected.deletions = 3
        expected.changedFiles = 4
        expected.commits = 1
        #expect(context.pullRequest == expected)
    }

    @Test("a type change counts as one changed file, as on GitHub")
    func countsATypeChangeOnce() throws {
        let context = try Context.fixture(diff: SampleDiff.typeChange)
        #expect(context.git.diff.files.count == 2)
        #expect(context.pullRequest.changedFiles == 1)
        #expect(context.pullRequest.additions == 1)
        #expect(context.pullRequest.deletions == 1)
    }

    @Test("a pull request given is used as it is, sizes included")
    func keepsAGivenPullRequest() throws {
        let pullRequest = PullRequest.fixture(number: 42, title: "Fix the build", labels: ["bug"], additions: 7)
        let context = try Context.fixture(diff: SampleDiff.mixed, pullRequest: pullRequest)
        #expect(context.pullRequest == pullRequest)
    }

    @Test("without commits, the pull request's head is its one commit, on its base")
    func defaultsToOneCommit() throws {
        let pullRequest = PullRequest.fixture(title: "Fix the build", body: "Details.")
        let context = try Context.fixture(diff: SampleDiff.mixed, pullRequest: pullRequest)
        #expect(context.git.commits == [.fixture(
            sha: pullRequest.head.commit,
            parents: [pullRequest.base.commit],
            subject: "Fix the build",
            body: "Details."
        )])
    }

    @Test("commits given are the context's, and count toward the default pull request's size")
    func takesCommits() throws {
        let commits = [
            Commit.fixture(sha: String(repeating: "1", count: 40), subject: "First"),
            Commit.fixture(sha: String(repeating: "2", count: 40), parents: [String(repeating: "1", count: 40)]),
        ]
        let context = try Context.fixture(diff: SampleDiff.mixed, commits: commits)
        #expect(context.git.commits == commits)
        #expect(context.pullRequest.commits == 2)
    }

    @Test("the merge base, the head, and the built commit are the pull request's")
    func takesCommitsFromThePullRequest() throws {
        let pullRequest = PullRequest.fixture(
            base: .init(name: "release", commit: String(repeating: "a", count: 40), repository: "o/r"),
            head: .init(name: "fix", commit: String(repeating: "b", count: 40), repository: "o/r")
        )
        let context = try Context.fixture(diff: SampleDiff.mixed, pullRequest: pullRequest)
        #expect(context.git.mergeBase == String(repeating: "a", count: 40))
        #expect(context.git.head == String(repeating: "b", count: 40))
        #expect(context.run.builtCommit == String(repeating: "b", count: 40))
    }

    @Test("the run is GitHub Actions' on github.com, in the workspace given")
    func describesTheRun() throws {
        let context = try Context.fixture(diff: SampleDiff.mixed, workspace: "/tmp/checkout")
        #expect(context.run.mode == .actions)
        #expect(context.run.workspace == "/tmp/checkout")
        #expect(context.run.lineMap == .identity)
        #expect(context.run.apiURL.absoluteString == "https://api.github.com")
        #expect(context.run.serverURL.absoluteString == "https://github.com")
        #expect(try Context.fixture(diff: SampleDiff.mixed).run.workspace == "/workspace")
    }

    @Test("a context line an editor trimmed to nothing is still a context line")
    func acceptsTrimmedContextLines() throws {
        let trimmed = SampleDiff.mixed.replacing("\n \n", with: "\n\n")
        #expect(trimmed != SampleDiff.mixed)
        let context = try Context.fixture(diff: trimmed)
        #expect(context.git.diff.damage.isEmpty)
        #expect(context.git.file(at: "Sources/App.swift")?.lines.count == 4)
    }

    @Test("an empty diff makes a context without files")
    func acceptsAnEmptyDiff() throws {
        let context = try Context.fixture(diff: "")
        #expect(context.git.diff.files.isEmpty)
        #expect(context.pullRequest.changedFiles == 0)
    }

    @Test("a damaged diff throws, naming where it's damaged")
    func rejectsDamage() {
        let error = #expect(throws: Context.FixtureError.self) {
            try Context.fixture(diff: SampleDiff.cutShort)
        }
        #expect(error?.damage == Diff(diff: SampleDiff.cutShort).damage)
        #expect(error?.damage.isEmpty == false)
        #expect(error?.description.contains("The diff is damaged at line") == true)
        #expect(error?.description.contains("(A.swift)") == true)
    }
}
