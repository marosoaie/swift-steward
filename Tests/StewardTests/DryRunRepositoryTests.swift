import Foundation
@testable import Steward
import Testing

/// Where a dry run finds its repository, which its links and
/// `--pull-request` need, over `DryRunTests`' fixture.
@Suite("A dry run's repository")
struct DryRunRepositoryTests {
    @Test("an origin remote on the server's host names the repository, for links")
    func origin() async throws {
        let fixture = try DryRunTests.checkedOutFixture()
        defer { fixture.remove() }
        try fixture.repository.git(["remote", "add", "origin", "git@github.com:marosoaie/swift-steward.git"])
        let context = try await DryRunTests.context(["--base", "main"], in: fixture)
        #expect(context.pullRequest.base.repository == "marosoaie/swift-steward")
        let elsewhere = try await DryRunTests.context(
            ["--base", "main"],
            environment: ["GITHUB_SERVER_URL": "https://ghe.example.com"],
            in: fixture
        )
        #expect(elsewhere.pullRequest.base.repository.isEmpty)
        #expect(elsewhere.run.serverURL.absoluteString == "https://ghe.example.com")
    }

    @Test("an origin behind an SSH host alias names none, and GITHUB_REPOSITORY names it instead")
    func hostAlias() async throws {
        let fixture = try DryRunTests.checkedOutFixture()
        defer { fixture.remove() }
        try fixture.repository.git(["remote", "add", "origin", "github-work:marosoaie/swift-steward.git"])
        let alias = try await DryRunTests.context(["--base", "main"], in: fixture)
        #expect(alias.pullRequest.base.repository.isEmpty)
        let named = try await DryRunTests.context(
            ["--base", "main"],
            environment: ["GITHUB_REPOSITORY": "marosoaie/swift-steward"],
            in: fixture
        )
        #expect(named.pullRequest.base.repository == "marosoaie/swift-steward")
    }
}
