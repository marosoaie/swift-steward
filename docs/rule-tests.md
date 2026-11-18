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
        .package(url: "https://github.com/marosoaie/swift-steward.git", .upToNextMinor(from: "0.2.0")),
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

## A rule in a group

A group's rules keep its condition, so a test of one gets what a run
gets. Name the group's rules as a static property, which `rules` lists
like a rule, and take a rule from it:

```swift
static var rules: [Rule] {
    changelog
    sources
}

static let sources = Rule.group(whenChangesMatch: "Sources/**") {
    Rule("Tests") { context in
        try context.git.changes(matching: "Tests/**").diff.files.isEmpty
            ? [.warning("Changes Sources without changing Tests.")] : []
    }
}
```

```swift
@Test("the tests rule applies only where Sources changes")
func testsRule() async throws {
    let rule = try #require(Checks.sources.first)
    let docs = try Context.fixture(diff: """
        diff --git a/README.md b/README.md
        index 1111111..2222222 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -Old
        +New
        """)
    #expect(try !rule.applies(to: docs))
    #expect(try await rule.evaluate(docs).isEmpty)
}
```

`applies(to:)` says whether the run would call the rule: whether every
group around it holds. Where one doesn't, `evaluate(_:)` returns no
findings, as the run would; `applies(to:)` tells that from a pass. Both
throw what a group's condition throws, such as the error for a malformed
pattern. Setting `evaluate` replaces the check and keeps the groups.

## A rule that reads files

A rule reads a file as the head commit has it through
`context.contents(ofFileAt:)`. Its test gives the fixture that file in
`files:`, beside the diff:

```swift
static let toolsVersion = Rule("Tools version") { context in
    guard context.git.modifiedFiles.contains("Package.swift"),
          case .bytes(let bytes) = try await context.contents(ofFileAt: "Package.swift")
    else { return [] }
    let firstLine = String(decoding: bytes.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
    return firstLine == "// swift-tools-version: 6.2"
        ? [] : [.warning("Build with Swift 6.2.", at: Location(path: "Package.swift", line: 1))]
}
```

```swift
@Test("an edited package that doesn't build with Swift 6.2 gets a warning at its first line")
func oldToolsVersion() async throws {
    let context = try Context.fixture(
        diff: """
            diff --git a/Package.swift b/Package.swift
            index 1111111..2222222 100644
            --- a/Package.swift
            +++ b/Package.swift
            @@ -2,5 +2,6 @@
             import PackageDescription

             let package = Package(
            -    name: "App"
            +    name: "App",
            +    platforms: [.macOS(.v14)]
             )
            """,
        files: ["Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "App",
                platforms: [.macOS(.v14)]
            )

            """]
    )
    let findings = try await Checks.toolsVersion.evaluate(context)
    #expect(findings == [.warning("Build with Swift 6.2.", at: Location(path: "Package.swift", line: 1))])
}
```

The diff and the files are given apart, so they could disagree, and a
test would then pass on a pull request no run could see. The fixture
checks them against each other, and throws when they disagree; see the
files under [The context](#the-context).

A rule from `Rule.changedFiles(_:in:excluding:limit:_:)` reads each
changed file the same way, so its test gives the files the same way.
The repository's own JSON rule, in `Dangerfile/`, is tested so: a file
that doesn't parse fails at its path, and the rest pass. A file the
diff lists at the head that `files:` leaves out is a failure of such a
rule, as a missing file is in a run.

## The context

`Context.fixture(diff:files:pullRequest:commits:workspace:)` builds the
context a GitHub Actions run builds for a pull request with that diff:

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
  what its rule reads, in this order: `number`, `title`, `body`,
  `author`, `state`, `isDraft`, `base`, `head`, `labels`, `webURL`,
  `additions`, `deletions`, `changedFiles`, `commits`. A pull request you
  give is used as it is, sizes included.
- **The commits** are one when you give none: the pull request's head on
  its base, with its title and description. `Commit.fixture` and
  `Commit.Signature.fixture` default every field too.
- **The run** is in `.actions` mode on github.com, built on the head
  commit, in `/workspace` unless you give `workspace` (a rule that reads a
  file, such as a build log, reads it under `context.run.workspace`).
  `context.git.mergeBase` and `context.git.head` are the pull request's
  base and head commits.
- **The files** are those you give in `files`, by path, as the head
  commit has them; none when you give none. `context.contents(ofFileAt:)`
  reads them as a run reads the head's: a path is matched byte for byte,
  a path with files under it is `.notRegularFile`, a file over the limit
  is `.tooLarge`, and any other path is `.noSuchFile`, as is every path
  at the merge base. Give the files the rule reads; the diff's other
  files can stay out. Each file you give must agree with the diff: hold
  its context and added lines at the numbers its hunk headers give, and
  end in a line break unless the diff says `\ No newline at end of
  file`. A file the diff creates holds its lines and nothing more, and
  so does one ending with a hunk that deletes its unterminated last
  line. A hunk that only deletes, as `-U0` writes one, keeps the line
  before what it deletes, so the file has that line, with its newline.
  A file the diff deletes, renames away, or makes a symbolic link or a
  submodule can't be given, and neither can one at a path no file in git
  has, such as `./Package.swift`, `a//b` or `dir/`, which a run reads as
  `.noSuchFile`. Where one disagrees, the fixture throws
  `Context.FixtureError`, naming the file and its first line that does.

Every part of a `Context` is a `var`, so a test changes what it needs
afterwards, such as `context.run.mode = .dryRun`, or `context.files`,
for a rule that reads the merge base's files too, or one whose reads
fail. `FakeRepositoryFiles` holds files by commit, and any
`RepositoryFiles` of your own works; a reader you set isn't checked
against the diff:

```swift
var context = try Context.fixture(diff: SampleDiff.toolsVersion)
context.files = FakeRepositoryFiles([
    context.git.head: ["Package.swift": Array(SampleSource.newPackage.utf8)],
    context.git.mergeBase: ["Package.swift": Array(SampleSource.oldPackage.utf8)],
])

struct FailingFiles: RepositoryFiles {
    func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
        throw CancellationError()
    }
}
context.files = FailingFiles()
```

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

A rule made with `Rule(_:check:)` writes lines to the run's log, which
`evaluate` drops. To test them, run the Dangerfile and look in
`outcome.log`, where each rule's lines come before the line counting its
findings:

```swift
#expect(outcome.log.contains("Snapshots: not comparing Tests/Snapshots/home.png\n"))
```

In CI mode, the fixture's default, the log holds GitHub Actions'
workflow commands: the rules' `::group::`, and a line that could pass
for a command between `::stop-commands::steward-fixture` and
`::steward-fixture::`. A dry run escapes it instead.

The fixture run has no command-line options and no environment of its
own: it writes no report file, its summary links to no workflow run, and
its token goes nowhere but the host. The fake host doesn't simulate
GitHub's failures (rate limits, outages); a rule test doesn't need them,
and Steward's own tests cover how a run handles them.

## The diagnostics rule

`Rule.diagnosticsOnChangedLines(in:failingOn:named:)` reads its
reports under `context.run.workspace`, so its test writes one into a
directory of its own and builds the context there:

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

A finding's text is Markdown, as the summary renders it: the tool's
message, with Markdown's punctuation escaped by a backslash so it shows
as written, then the rule, if the log names one, as a code span.
SwiftLint's output names its rule, so the same test for it expects the
rule after the message:

```swift
try """
    /ci/checkout/Sources/App.swift:2:23: warning: Trailing Whitespace Violation: Lines should not have trailing whitespace (trailing_whitespace)
    """.write(to: workspace.appendingPathComponent("swiftlint.log"), atomically: true, encoding: .utf8)
let context = try Context.fixture(diff: ChangelogTests.sourcesOnly, workspace: workspace.path)
let findings = try await Rule.diagnosticsOnChangedLines(in: [.swiftLint("swiftlint.log")]).evaluate(context)
#expect(findings == [.warning(
    "Trailing Whitespace Violation: Lines should not have trailing whitespace (`trailing_whitespace`)",
    at: Location(path: "Sources/App.swift", line: 2)
)])
```

Backticks in a message come escaped too: for SwiftLint's `empty_count`,
a test expects
``#"Empty Count Violation: Prefer checking \`isEmpty\` over comparing \`count\` to zero (`empty_count`)"#``,
a raw string, so the backslashes stay. A missing report is one failure
without a location, whose text starts
``Couldn't read the xcodebuild log `build.log`:`` ("the SwiftLint
output" for `.swiftLint`, and so on), then the system's reason, which
macOS and Linux word differently.

A report's paths resolve as in a run: a path to a file under the
workspace is that file, and any other matches the pull request's path it
ends with, so a CI runner's absolute paths work as they are. A fixture's
line map is the identity, so the report's line numbers are the head's.
Leave out `builtAt:`: it maps a report through git in the checkout, which
a fixture doesn't have, so the rule reports a failure. `evaluate(_:)`
drops what the rule logs; a whole run's log says how many
diagnostics each report held, matched, and dropped.
