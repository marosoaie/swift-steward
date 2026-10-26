import Foundation
@testable import GitHubAPI
import HTTPTypes
import OpenAPIRuntime
import PullRequestHosting
@testable import Steward
import StewardVersion
import Testing

/// Dry runs, in-process, over `PullRequestFixture` checked out at its head.
/// Every host they could make sends its requests to a transport that fails
/// the test, unless the test reads a pull request on purpose.
@Suite("A dry run")
struct DryRunTests {
    @Test("a dry run prints the summary, logs plain lines, never asks the network, and exits as a CI run would")
    func run() async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        let recording = RecordingConsole()
        let status = await Runner.testing(["--base", "main"], environment: [:], directory: fixture.repository.path,
                                          recording: recording)
            .run(RunnerTests.rules)
        let (output, log) = await recording.finishStreams()
        let short = String(fixture.head.prefix(7))
        #expect(status == .failures)
        // No repository: no GITHUB_REPOSITORY, no origin remote, so no links.
        #expect(output == """
            **1 failure, 2 warnings, 1 message, 1 note** on \(short)

            | | Failures |
            |---|---|
            | :no_entry_sign: | Too many files |

            | | Warnings |
            |---|---|
            | :warning: | Gone: gone.swift<br>`gone.swift` |
            | :warning: | Gone: old.swift<br>`old.swift` |

            | | Messages |
            |---|---|
            | :book: | Line 15 changed<br>`a.swift:15` |

            ## Notes

            <sub>Steward \(Release.version) · dry run with a placeholder pull request · \(short)</sub>

            """)
        #expect(log.hasPrefix("Pull request #0 in : feature into main\n"))
        #expect(!log.contains("::"))
    }

    @Test("the placeholder comes from the head commit, the git user, and the local changes, sized as GitHub would")
    func placeholder() async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        let subdirectory = fixture.repository.url.appendingPathComponent("dir with space")
        let context = try await Self.context(["--base", "main"], in: subdirectory)
        let pullRequest = context.pullRequest
        #expect(pullRequest.number == 0)
        #expect(pullRequest.title == "Make run.sh executable")
        #expect(pullRequest.body.isEmpty)
        #expect(pullRequest.author == "Ada Lovelace")
        #expect(pullRequest.state == .open)
        #expect(!pullRequest.isDraft)
        #expect(pullRequest.labels.isEmpty)
        #expect(pullRequest.webURL.isEmpty)
        #expect(pullRequest.base == PullRequest.Branch(name: "main", commit: fixture.base, repository: ""))
        #expect(pullRequest.head == PullRequest.Branch(name: "feature", commit: fixture.head, repository: ""))
        // git's own count of the changes from the merge base, binary files
        // and renames as files without lines.
        let numstat = try fixture.repository.git(["diff", "--numstat", "-M", fixture.forkPoint, fixture.head])
            .split(separator: "\n").map { $0.split(separator: "\t") }
        #expect(pullRequest.additions == numstat.compactMap { Int($0[0]) }.reduce(0, +))
        #expect(pullRequest.deletions == numstat.compactMap { Int($0[1]) }.reduce(0, +))
        #expect(pullRequest.changedFiles == numstat.count)
        #expect(pullRequest.commits == 2)

        let root = URL(fileURLWithPath: try fixture.repository.git(["rev-parse", "--show-toplevel"]))
        #expect(context.run.mode == .dryRun)
        #expect(context.run.workspace == root.path)
        #expect(context.run.builtCommit == fixture.head)
        #expect(context.run.lineMap == .identity)
        #expect(context.git.mergeBase == fixture.forkPoint)
    }

    @Test("the placeholder's author is the git user when there is one, and its repository GITHUB_REPOSITORY")
    func userAndRepository() async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        try fixture.repository.git(["config", "user.name", "Grace Hopper"])
        let context = try await Self.context(["--base=main"], environment: ["GITHUB_REPOSITORY": "o/r"], in: fixture)
        #expect(context.pullRequest.author == "Grace Hopper")
        #expect(context.pullRequest.base.repository == "o/r")
        #expect(!context.pullRequest.isFromFork)
    }

    @Test("a checkout's path and the git user keep line breaks of their own, past the one git ends a line with")
    func lineBreaks() async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        try fixture.repository.git(["config", "user.name", "Grace Hopper\n"])
        // Both file systems allow a line break at the end of a name.
        let checkout = fixture.repository.root.appendingPathComponent("checkout\n", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.repository.url, to: checkout)
        let context = try await Self.context(["--base", "main"], in: checkout)
        let topLevel = try Subprocess.output(
            of: ["git", "-C", checkout.path, "rev-parse", "--show-toplevel"],
            environment: TestRepository.environment
        )
        #expect(context.run.workspace.hasSuffix("/checkout\n"))
        #expect(Data("\(context.run.workspace)\n".utf8) == topLevel)
        #expect(context.pullRequest.author == "Grace Hopper\n")
        #expect(context.git.head == fixture.head)
    }

    @Test("the base defaults to origin's default branch, and a detached head is named HEAD")
    func defaultBase() async throws {
        let fixture = try PullRequestFixture()
        defer { fixture.remove() }
        try fixture.repository.git(["switch", "--quiet", "main"])
        let clone = try TestRepository(cloning: fixture.repository)
        defer { clone.remove() }
        try clone.git(["switch", "--quiet", "--detach", fixture.head])
        let context = try await Self.context([], in: clone.url)
        #expect(context.pullRequest.base == PullRequest.Branch(name: "main", commit: fixture.base, repository: ""))
        #expect(context.pullRequest.head.name == "HEAD")
        #expect(context.git.head == fixture.head)
    }

    @Test("the repository comes from an origin remote on the server's host, for links")
    func originRepository() async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        try fixture.repository.git(["remote", "add", "origin", "git@github.com:marosoaie/swift-steward.git"])
        let context = try await Self.context(["--base", "main"], in: fixture)
        #expect(context.pullRequest.base.repository == "marosoaie/swift-steward")
        let elsewhere = try await Self.context(
            ["--base", "main"],
            environment: ["GITHUB_SERVER_URL": "https://ghe.example.com"],
            in: fixture
        )
        #expect(elsewhere.pullRequest.base.repository.isEmpty)
        #expect(elsewhere.run.serverURL.absoluteString == "https://ghe.example.com")
    }

    @Test("--pull-request reads the pull request through pulls/get, with the token when there is one", arguments: [
        "probe-token-77", nil,
    ])
    func pullRequest(token: String?) async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        let transport = try PullRequestTransport(
            owner: "marosoaie", repository: "swift-steward", number: 26, fixture: "swift-steward-26", token: token
        )
        var environment = ["GITHUB_REPOSITORY": "marosoaie/swift-steward"]
        environment["GITHUB_TOKEN"] = token
        let recording = RecordingConsole()
        let status = await Runner.testing(
            ["--base", "main", "--pull-request", "26"],
            environment: environment,
            directory: fixture.repository.path,
            recording: recording,
            transport: transport
        ).run([Rule("Title") { context in [.message("\(context.pullRequest.number): \(context.pullRequest.title)")] }])
        let (output, log) = await recording.finishStreams()
        #expect(status == .clean)
        #expect(output.contains("| :book: | 26: Depend on GitDiffKit 0.2.0 and require macOS 26 (step 2.9) |"))
        #expect(output.contains("<sub>Steward \(Release.version) · dry run · \(fixture.head.prefix(7))</sub>"))
        #expect(log.hasPrefix("""
            Pull request #26 in marosoaie/swift-steward: claude/step-2-9-library-0-2-0-a056d5 into main
            """))
    }

    @Test("a dry run that can't build its context exits 2 and says why", arguments: [
        (["--base", "nope"], ContextError.unknownBase("nope").description),
        (["--base=-x"], ContextError.unknownBase("-x").description),
        ([], ContextError.noDefaultBase.description),
        (["--base", "main", "--pull-request", "26"], ContextError.unknownRepository(host: "github.com").description),
    ])
    func broken(arguments: [String], message: String) async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        let recording = RecordingConsole()
        let status = await Runner.testing(arguments, environment: [:], directory: fixture.repository.path,
                                          recording: recording)
            .run(RunnerTests.rules)
        let (output, log) = await recording.finishStreams()
        #expect(status == .broken)
        #expect(output.isEmpty)
        #expect(log == "error: \(message)\n")
    }

    @Test("outside a checkout, in an empty repository, or with a malformed GITHUB_REPOSITORY, there is no context")
    func noContext() async throws {
        let empty = try TestRepository()
        defer { empty.remove() }
        await #expect(throws: ContextError.unbornHead) { try await Self.context(["--base", "main"], in: empty.url) }

        let outside = empty.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let error = await #expect(throws: ContextError.self) { try await Self.context([], in: outside) }
        guard case .notACheckout(let directory, _) = error else {
            Issue.record("\(String(describing: error)) isn't notACheckout")
            return
        }
        #expect(directory == outside.path)

        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        await #expect(throws: ContextError.invalidRepository("nope")) {
            try await Self.context(["--base", "main"], environment: ["GITHUB_REPOSITORY": "nope"], in: fixture)
        }
    }

    @Test("the transport the other dry runs use fails a test on any request")
    func forbiddenTransport() async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        await withKnownIssue {
            // The refused request fails the read too, which isn't the point.
            _ = try? await Self.context(
                ["--base", "main", "--pull-request", "26"],
                environment: ["GITHUB_REPOSITORY": "marosoaie/swift-steward"],
                in: fixture
            )
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("GET /repos/marosoaie/swift-steward/pulls/26 went out") }
        }
    }

    @Test("a pull request the host can't read ends the run, naming it")
    func unreadablePullRequest() async throws {
        let fixture = try Self.checkedOutFixture()
        defer { fixture.remove() }
        let error = await #expect(throws: ContextError.self) {
            try await Self.context(
                ["--base", "main", "--pull-request", "404"],
                environment: ["GITHUB_REPOSITORY": "marosoaie/swift-steward"],
                in: fixture,
                transport: NotFoundTransport()
            )
        }
        guard case .unreadablePullRequest(404, _) = error else {
            Issue.record("\(String(describing: error)) isn't unreadablePullRequest(404)")
            return
        }
    }

    /// The fixture with its head checked out, as a developer's would be.
    static func checkedOutFixture() throws -> PullRequestFixture {
        let fixture = try PullRequestFixture()
        try fixture.repository.git(["switch", "--quiet", "feature"])
        return fixture
    }

    static func context(
        _ arguments: [String],
        environment: [String: String] = [:],
        in fixture: PullRequestFixture,
        transport: any ClientTransport = ForbiddenTransport()
    ) async throws -> Context {
        try await context(arguments, environment: environment, in: fixture.repository.url, transport: transport)
    }

    /// The dry run's context for `arguments`, run in `directory`, built as
    /// the runner builds it.
    static func context(
        _ arguments: [String],
        environment: [String: String] = [:],
        in directory: URL,
        transport: any ClientTransport = ForbiddenTransport()
    ) async throws -> Context {
        let runner = Runner.testing(
            arguments,
            environment: environment,
            directory: directory.path,
            recording: RecordingConsole(),
            transport: transport
        )
        return try await Context.dryRun(
            options: Options(arguments: arguments),
            environment: runner.environment,
            directory: runner.currentDirectory,
            makeHost: runner.makeHost
        )
    }
}
