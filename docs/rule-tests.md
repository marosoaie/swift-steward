# Testing a Dangerfile's rules

A Dangerfile's rules are values, so a test calls one on a context built
from a diff and checks what it found. `StewardTesting` builds that context
the way a real run does, and runs a whole Dangerfile against a fake host
that records what it would post. [danger.md](danger.md), section 8, is the
design behind this page.

## The package

A Dangerfile is an ordinary package beside your own: an executable target
that depends on `Steward`, and a test target that depends on the
executable target and `StewardTesting`. The [quickstart](quickstart.md)'s
template is one, with a test for each of its rules.

```swift
// swift-tools-version: 6.2
// Dangerfile/Package.swift
import PackageDescription

let package = Package(
    name: "Dangerfile",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/marosoaie/swift-steward.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "Dangerfile",
            dependencies: [.product(name: "Steward", package: "swift-steward")]
        ),
        .testTarget(
            name: "DangerfileTests",
            dependencies: ["Dangerfile", .product(name: "StewardTesting", package: "swift-steward")]
        ),
    ]
)
```

`swift test --package-path Dangerfile` runs the tests, on macOS and on
Linux. `StewardTesting` re-exports `Steward`, which re-exports
`GitDiffKit` and `PullRequestHosting`, so a test file imports only
`StewardTesting`, `Testing`, and the Dangerfile.

## Rules a test can name

A rule the tests need is a static property, listed in `rules` by name:

```swift
// Dangerfile/Sources/Dangerfile/Checks.swift
import Steward

@main
struct Checks: Dangerfile {
    static var rules: [Rule] {
        changelog
    }

    static let changelog = Rule("Changelog") { context in
        guard !context.git.modifiedFiles.contains("CHANGELOG.md") else { return [] }
        return [.warning("Add a CHANGELOG entry.")]
    }
}
```

The test target reaches it with `@testable import Dangerfile`. A rule
written inline in `rules` still runs; only a test can't call it alone.

## A rule test

A rule test is one call: build a context, evaluate the rule, compare the
findings.

```swift
// Dangerfile/Tests/DangerfileTests/ChangelogTests.swift
@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Changelog")
struct ChangelogTests {
    @Test("a pull request without a changelog entry gets a warning")
    func missingChangelog() async throws {
        let context = try Context.fixture(diff: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1111111..2222222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1,2 +1,3 @@
             import Foundation
            +let greeting = "Hello"
             print(greeting)
            """)
        let findings = try await Checks.changelog.evaluate(context)
        #expect(findings == [.warning("Add a CHANGELOG entry.")])
    }
}
```

`evaluate(_:)` returns the rule's findings as the rule wrote them, and
throws what the rule throws. In a run, the runner adds the rule's name to
each finding and turns a thrown error into a failure.

## The context

`Context.fixture(diff:pullRequest:commits:workspace:)` builds the context
a GitHub Actions run builds for a pull request with that diff:

- **The diff** goes through the parser a real run uses, with the same
  options, so `context.git.diff`, the file lists, and `file(at:)` are what
  a run sees for that text. Give it as `git diff` writes it, from
  `diff --git` on. A context line that is only a space may lose it, as
  editors trim them; anything else git wouldn't write, such as a hunk
  header whose line counts don't match its lines, throws
  `Context.FixtureError`, which lists where the parser found damage. (A
  real run works around damage, dropping a file it can't read; a test
  would then check a diff its author didn't mean.)
- **The pull request** is `PullRequest.fixture()` when you give none: an
  open pull request #1 in `octocat/hello-world` from `feature` into
  `main`, with additions, deletions, changed files, and commits counted
  from the diff and the commits as GitHub counts them. `PullRequest.fixture`
  takes every field as an argument with a default, so a test names only
  what its rule reads. A pull request you give is used as it is, sizes
  included.
- **The commits** are one when you give none: the pull request's head on
  its base, with its title and description. `Commit.fixture` and
  `Commit.Signature.fixture` default every field too.
- **The run** is in `.actions` mode on github.com, built on the head
  commit, in `/workspace` unless you give `workspace` (a rule that reads a
  file, such as a build log, reads it under `context.run.workspace`).
  `context.git.mergeBase` and `context.git.head` are the pull request's
  base and head commits.

Every part of a `Context` is a `var`, so a test changes what it needs
afterwards, such as `context.run.mode = .dryRun`.

## The whole Dangerfile

`Checks.run(on: context)` runs every rule as `main()` does once it has
built its context, and returns a `RunOutcome`: the exit status, the
report, the summary, and the log. Everything after the context is a real
run's: the rules in order, a thrown error as a failure, the report, the
summary cut to the host's size, the job summary, and the sticky comment.

With the rule test's diff as `static let sourcesOnly` in
`ChangelogTests`:

```swift
@Test("a pull request without a changelog entry passes with a warning")
func wholeRun() async throws {
    let context = try Context.fixture(diff: ChangelogTests.sourcesOnly)
    let host = FakePullRequestHost(pullRequest: context.pullRequest)
    let outcome = await Checks.run(on: context, postingTo: host)
    #expect(outcome.exitStatus == 0)
    #expect(outcome.report?.findings.map(\.rule) == ["Changelog"])
    #expect(await host.comments.map(\.body) == [outcome.summary])
}
```

`FakePullRequestHost` answers as GitHub does through Steward's
`GitHubHost`, which Steward's own tests check against a simulated GitHub:

- `comments:` seeds summary comments from earlier runs (more than one
  after two runs raced, which the run then deduplicates); `comments` is
  what the pull request shows afterwards, and `requests` every call the
  run made, in order.
- `push(_:)` moves the pull request's head, so a run for the old head
  stops before writing.
- By default it takes as much as a GitHub comment holds, so the run cuts
  the summary where it would on GitHub; `maximumSummarySize:` sets
  another limit. A longer comment is refused, as GitHub refuses it.

`run(on:)` without a host posts to a fresh fake host for the context's
pull request. A pull request whose head is in another repository
(`pullRequest.head.repository = "someone/hello-world"`) is a fork's: the
rules run, and nothing is posted, as in CI. A dry run (`context.run.mode = .dryRun`) puts the printed
summary in `outcome.summary` and sends the host nothing.

The fixture run has no command-line options and no environment of its
own: it writes no report file, its summary links to no workflow run, and
its token goes nowhere but the host. The fake host doesn't simulate
GitHub's failures (rate limits, outages); a rule test doesn't need them,
and Steward's own tests cover how a run handles them.

## The diagnostics rule

`Rule.diagnosticsOnChangedLines(in:failingOn:)` reads its reports under
`context.run.workspace`, so its test writes one into a directory of its
own and builds the context there:

```swift
// Dangerfile/Tests/DangerfileTests/BuildLogTests.swift
import Foundation
import StewardTesting
import Testing

@Suite("Build log")
struct BuildLogTests {
    @Test("a warning on an added line is reported at that line")
    func warningOnAddedLine() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try """
            /ci/checkout/Sources/App.swift:2:5: warning: initialization of immutable value 'greeting' was never used
            """.write(to: workspace.appendingPathComponent("build.log"), atomically: true, encoding: .utf8)
        let context = try Context.fixture(diff: ChangelogTests.sourcesOnly, workspace: workspace.path)
        let findings = try await Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log")]).evaluate(context)
        #expect(findings == [.warning(
            "initialization of immutable value 'greeting' was never used",
            at: Location(path: "Sources/App.swift", line: 2)
        )])
    }
}
```

A report's paths resolve as in a run: a path to a file under the
workspace is that file, and any other matches the pull request's path it
ends with, so a CI runner's absolute paths work as they are. A fixture's
line map is the identity, so the report's line numbers are the head's.
Leave out `builtAt:`: it maps a report through git in the checkout, which
a fixture doesn't have, so the rule reports a failure. `evaluate(_:)`
drops what the rule logs; a whole run's log says how many
diagnostics each report held, matched, and dropped.
