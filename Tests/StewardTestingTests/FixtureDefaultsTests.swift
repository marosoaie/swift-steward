import Foundation
import StewardTesting
import Testing

@Suite("PullRequest.fixture and Commit.fixture")
struct FixtureDefaultsTests {
    @Test("the default pull request is an open one, from a branch of the same repository")
    func defaultPullRequest() {
        let pullRequest = PullRequest.fixture()
        #expect(pullRequest.number == 1)
        #expect(pullRequest.title == "Add a feature")
        #expect(pullRequest.body.isEmpty)
        #expect(pullRequest.author == "octocat")
        #expect(pullRequest.state == .open)
        #expect(!pullRequest.isDraft)
        #expect(pullRequest.base == .init(
            name: "main",
            commit: String(repeating: "ba5e", count: 10),
            repository: "octocat/hello-world"
        ))
        #expect(pullRequest.head == .init(
            name: "feature",
            commit: String(repeating: "4ead", count: 10),
            repository: "octocat/hello-world"
        ))
        #expect(!pullRequest.isFromFork)
        #expect(pullRequest.labels.isEmpty)
        #expect(pullRequest.webURL == "https://github.com/octocat/hello-world/pull/1")
        let sizes: [Int] = [pullRequest.additions, pullRequest.deletions, pullRequest.changedFiles, pullRequest.commits]
        #expect(sizes == [0, 0, 0, 0])
    }

    @Test("the default page follows the number and the base repository; a page given is kept")
    func webURL() {
        let base = PullRequest.Branch(name: "main", commit: String(repeating: "a", count: 40), repository: "o/r")
        #expect(PullRequest.fixture(number: 9, base: base).webURL == "https://github.com/o/r/pull/9")
        #expect(PullRequest.fixture(webURL: "https://example.com/9").webURL == "https://example.com/9")
    }

    @Test("the default commit is the default pull request's head, on its base")
    func defaultCommit() {
        let commit = Commit.fixture()
        let pullRequest = PullRequest.fixture()
        #expect(commit.sha == pullRequest.head.commit)
        #expect(commit.parents == [pullRequest.base.commit])
        #expect(commit.subject == pullRequest.title)
        #expect(commit.body.isEmpty)
        #expect(commit.author == .fixture())
        #expect(commit.committer == .fixture())
    }

    @Test("the default signature is fixed, so output never depends on when a test runs")
    func defaultSignature() {
        let signature = Commit.Signature.fixture()
        #expect(signature.name == "Octocat")
        #expect(signature.email == "octocat@example.com")
        #expect(signature.date == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(Commit.Signature.fixture(name: "Ada").name == "Ada")
    }
}
