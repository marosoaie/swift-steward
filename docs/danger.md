# Steward: a pure-Swift Danger

**Status: draft for review (plan step 4.1).** No Phase 4 code exists yet;
steps 4.2–4.10 build on what this document settles. Each section ends with
a recommendation and the alternatives weighed, and the
[open questions](#open-questions) at the end are for the maintainer to
answer. Claims about danger-swift, GitHub, and SwiftPM were checked
against their sources or by experiment; [Checks](#checks) lists how.

## Decisions at a glance

| # | Topic | Recommendation | Alternatives considered |
|---|---|---|---|
| S1 | Rule shape | `Rule`: a name plus a pure `@Sendable (Context) async throws -> [Finding]`; rules composed with a result builder; a thrown error becomes a failure of that rule | An `inout` report; a `Rule` protocol; danger-swift's global `danger` and free `warn()` |
| S2 | Context | One immutable `Context`: `pullRequest` from the event payload (no API call), `git` from the local checkout through the full model, eagerly; `String` paths in the file lists, bytes in `diff` | Lazy git data; reading the PR through the API; a `github` namespace; `[DiffPath]` lists |

## Context and constraints

The plan's decisions (2026-10-22) fix the frame:

- **Rules live in the user's repository**, in a SwiftPM package
  (`Dangerfile/`) whose executable depends on the `Steward` library and
  *is* the runner: `swift run`. No Node, no danger-js, no separate binary.
- **The DSL is familiar but not source-compatible** with danger-swift:
  `warn`/`fail`/`message`/`markdown`, `git.modifiedFiles`,
  `github.pullRequest`, reshaped by the Swift API Design Guidelines,
  value types, and no globals.
- **v1 output** is one sticky summary comment plus a non-zero exit code
  when a rule fails. **v1 CI** is GitHub Actions on same-repository pull
  requests, talking to GitHub only through the `PullRequestHost` seam.
- **Names** (decision 1): the module is `Steward`, with `StewardTesting`
  for rule tests; no type may be called `Steward`, because it would
  shadow the module.

What already exists and this design builds on:

- **The full diff model** from git-diff-parser
  ([`docs/diff-model.md`](https://github.com/marosoaie/git-diff-parser/blob/main/docs/diff-model.md),
  reviewed): `Diff { files: [DiffFile] }`, each file a `FileHeader`
  (change kind, `DiffPath` byte paths, modes, binary flag), hunks, and
  `DiffLine`s with old and new line numbers; a `damage` event reports
  local recoveries (`.info`) and abandoned files (`.error`), which tools
  log. It lands in library 0.2.0, which raises swift-steward's macOS
  floor to 26 (step 2.9).
- **The host seam** (step 3.5, [`docs/github-api.md`](github-api.md#the-host-seam)):
  `PullRequestHost` reads a `PullRequest` and finds, creates, updates,
  and deletes the summary comment, which `GitHubHost` recognizes by the
  first line `<!-- steward-summary -->`. Errors are
  `PullRequestHostError` values whose `kind` says what a caller can do.
  `PullRequest` maps from an Actions event payload as well as from
  `pulls/get`.
- **The diagnostics pipeline**: `BuildLogKit` parses xcodebuild,
  SwiftLint, SwiftFormat, and SonarQube output into `Diagnostic`s, and
  `DiagnosticMatcher` keeps the ones on a diff's changed lines. The
  built-in rule (4.5) wraps them.

The repository's conventions apply throughout: structs and enums only,
behavior injected as `@Sendable` closures rather than subclassed,
functional style over loops, strict concurrency with no warnings,
macOS and Linux, and no third-party dependencies in libraries
(swift-argument-parser is allowed in the CLI target only, so `Steward`
can't use it).

## 1. The shape of a rule (S1)

A Dangerfile is a list of checks over one pull request. The plan names
two shapes; three more come up in practice:

| Shape | A rule is | Reports by |
|---|---|---|
| **A. Pure function** | `(Context) -> [Finding]` | returning findings |
| **B. `inout` report** | `(Context, inout Report) -> Void` | `report.warn(…)` |
| C. Protocol | a type conforming to `protocol Rule` | returning findings |
| D. Result builder for findings | a `@FindingsBuilder` closure | listing findings as statements |
| E. danger-swift's | top-level code | global `warn(…)` into a global `danger` |

E is ruled out by the conventions: its results live in global mutable
state. C makes every heterogeneous list `[any Rule]` (the package enables
`ExistentialAny`), and configuration that a protocol would carry in
stored properties is just as easily captured by a closure, which is how
`ClangStyleLogParser` injects its `refine` hook. D reads well in small
examples, but a result builder can't contain `guard`, `return`, `break`,
or `while`, its type errors point at the wrong line, and long bodies hit
"unable to type-check this expression in reasonable time", which the
library already had to work around once (`20ba4fd`).

That leaves A and B. They're equally testable, since each rule is a value
called with a context, and B's `report.warn("…")` is the closest to
danger-swift. A wins on the conventions: rules are expressions, so the
functional style the repository asks for falls out of them (`filter` the
files, `map` them to findings), and a rule can't read or drop another
rule's findings because it never sees them.

**Recommendation (A):**

```swift
/// One check over a pull request.
public struct Rule: Sendable {
    /// Names the rule in the report and the log.
    public var name: String
    /// The check itself. A thrown error becomes a failure of this rule.
    public var evaluate: @Sendable (Context) async throws -> [Finding]

    public init(_ name: String, evaluate: @escaping @Sendable (Context) async throws -> [Finding])
}

/// One thing a rule wants the pull request's author to see.
public struct Finding: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case failure, warning, message, markdown }
    public var kind: Kind
    public var text: String          // GitHub-flavored Markdown
    public var location: Location?   // a file, and optionally a line, on the head side
    public var rule: String?         // filled in by the runner

    public static func failure(_ text: String, at location: Location? = nil) -> Finding
    public static func warning(_ text: String, at location: Location? = nil) -> Finding
    public static func message(_ text: String, at location: Location? = nil) -> Finding
    public static func markdown(_ text: String) -> Finding
}
```

A Dangerfile package's executable conforms one type to a protocol whose
`main()` is the runner, the way swift-argument-parser's
`AsyncParsableCommand` provides `main()`:

```swift
import Steward

@main
struct PullRequestChecks: Dangerfile {
    static var rules: [Rule] {
        Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log"), .swiftLint("swiftlint.json")])

        Rule("Changelog") { context in
            guard !context.git.modifiedFiles.contains("CHANGELOG.md") else { return [] }
            return [.warning("Add a CHANGELOG entry.")]
        }

        Rule("No new Objective-C") { context in
            context.git.createdFiles
                .filter { $0.hasSuffix(".m") }
                .map { .failure("Write \($0) in Swift.", at: Location(path: $0)) }
        }
    }
}
```

`Dangerfile` declares `@RuleBuilder static var rules: [Rule] { get }`,
so conformers get the builder without writing it. The builder is over one
concrete type, so it stays cheap to type-check, and it accepts `if`,
`for`, and arrays of rules (`Rule.swiftLint(…)` can return several). The
two hand-written rules above, with this builder and stub types,
type-check under Swift 6.4 in Swift 6 mode, implicit-member `.failure`
inside `map` included.

The details:

- **Familiar names.** The four kinds keep danger-swift's vocabulary as
  static factories: `[.warning("…")]` reads close to `warn("…")`. Pure
  free functions `warn(_:)` and friends were weighed (a stray call would
  even warn about its unused result), but the API guidelines prefer
  members when there is an obvious type, and two spellings of one thing
  is one too many.
- **Errors degrade locally.** A rule that throws doesn't stop the run: the
  runner records `.failure("Rule “Changelog” failed: …")` for it and goes
  on, so one broken rule shows up in the summary instead of hiding the
  others. A rule can't make the check pass by crashing. Cancellation (the
  job was cancelled) stops the run without posting.
- **Order and concurrency.** Rules run one after another in declaration
  order, and findings keep that order. Rules that run tools
  (`swiftlint`, `xcodebuild`) then don't compete for the runner's cores,
  and logs read top to bottom. Because rules and the context are
  `Sendable`, running them in a task group later wouldn't change the API.
- **Async and throwing**, because real rules read logs, run processes,
  and parse files. A pure rule just doesn't use either.
- **No exit codes or I/O in rules.** The runner owns the exit status,
  posting, and the log; a rule only answers questions about the context.

*Trade-off:* a rule with several independent checks either returns an
array it builds up (`var findings: [Finding] = []`) or becomes several
rules. The second is usually better anyway: each finding names its rule
in the report.

## 2. The context (S2)

`Context` is everything a rule may look at, gathered once before the
first rule runs and then immutable:

```swift
public struct Context: Sendable {
    public var pullRequest: PullRequest   // PullRequestHosting's model
    public var git: GitChanges            // the pull request's changes, base...head
    public var run: Run                   // where Steward runs, and on which trees
}

public struct GitChanges: Sendable {
    public var diff: Diff                 // GitDiffKit's full model
    public var commits: [Commit]          // base..head, oldest first
    public var mergeBase: String          // commit SHAs
    public var head: String

    public var createdFiles: [String] { get }
    public var modifiedFiles: [String] { get }
    public var deletedFiles: [String] { get }
    public var renamedFiles: [Rename] { get }   // from, to
    public func file(at path: String) -> DiffFile?
}

public struct Commit: Sendable, Hashable {
    public var sha: String
    public var parents: [String]
    public var author: Signature          // name, email, date
    public var committer: Signature
    public var subject: String
    public var body: String
}

public struct Run: Sendable {
    public var mode: Mode                 // .actions, or .dryRun outside Actions
    public var workspace: String          // the checkout's root
    public var builtCommit: String        // the tree build logs refer to (section 3)
}

public struct Location: Sendable, Hashable, Codable {
    public var path: String               // repository-relative, `/`-separated
    public var line: Int?                 // 1-based, head side
    public init(path: String, line: Int? = nil)
}
```

Where each part comes from (step 4.2):

- **`pullRequest`** from the event payload at `GITHUB_EVENT_PATH`, through
  the mapping `GitHubHost` already uses for `pulls/get`
  ([`EventPayloadTests`](github-api.md#tests) decodes real payloads). No
  API call, so a rule can't burn rate limit or fail on the network just
  by reading the title. The payload is a snapshot from when the event
  fired: labels added since then aren't in it. v1 accepts `pull_request`
  events only (`opened`, `synchronize`, `reopened`, plus `edited` if the
  workflow lists it for title and body rules) and refuses any other event
  with a clear message, `pull_request_target` included, whose checkout is
  the base branch.
- **`git`** from the local checkout: `git diff` from the merge base to
  the head commit, parsed by the library's full-model entry point (64 MiB
  line cap), and `git log` over the same range. Both run once, eagerly;
  memory grows with the pull request's diff, which is fine at pull
  request sizes. Damage reports are logged to standard error, never shown
  in the summary. Steward pins every git option that changes the output's
  shape rather than trusting the user's configuration:
  `--no-color --no-ext-diff --no-textconv --no-relative
  --src-prefix=a/ --dst-prefix=b/ -M`, so `diff.noprefix`,
  `color.ui=always`, or an external diff tool can't break parsing. The
  log is read with NUL-separated `--format` fields, so any subject parses.
- **`run`** from the environment: `GITHUB_ACTIONS`, `GITHUB_WORKSPACE`,
  and `GITHUB_SHA` (the commit the workflow checked out, which for
  `pull_request` is the merge commit; see section 3). `GITHUB_API_URL` and
  `GITHUB_SERVER_URL` point the host and the summary's links at GitHub
  Enterprise without configuration.

The file lists follow the diff model: `createdFiles` are `.added`,
`deletedFiles` `.deleted`, `renamedFiles` `.renamed` (old and new path),
and `modifiedFiles` everything else that exists on both sides, including
renamed files under their new path, which matches what a reviewer sees
as "changed" in the Files tab. Steward passes `-M` but not `-C`, so a
copy shows up as a created file. Binary and mode-only changes are listed
like any other.

**Paths are `String`s in the conveniences, bytes in `diff`.** Rules
compare paths with literals (`contains("CHANGELOG.md")`), and findings,
links, and the JSON report all need text, so the lists decode
`DiffPath`'s bytes with its lossy `string`, which the library documents.
A rule that must tell two Latin-1 names apart uses `diff` and its
`DiffPath`s. Making the lists `[DiffPath]` was weighed; it's exact, but
every rule would convert, and two paths that decode to the same string
are rare enough to document instead.

**Locally** (the dry run, 4.3), there is no event payload. The head is
`HEAD`, the base is `--base <ref>` (default: the remote's default
branch), and `pullRequest` comes from `pulls/get` when `--pull-request
<n>` and a token are given. Without them, Steward fills in a placeholder
pull request from the head commit (its subject as the title, its body as
the description, the git user as the author) and says so in the printed
summary, rather than making `pullRequest` optional for every rule just
for the dry run. Open question 6 asks whether that placeholder is
acceptable.

Alternatives weighed:

- **Lazy git data** (run `git log` only when a rule asks): saves
  milliseconds, but makes reading a property fallible and async. Eager
  is simpler, and the diff is needed by the built-in rule anyway.
- **Reading pull request data through the API** every run: fresher labels,
  but one more request, one more failure mode, and a token for reading.
  A rule that needs live data can wait for a later version that exposes
  the host to rules; v1 doesn't.
- **A `danger.github` namespace** mirroring danger-swift (`context.github
  .pullRequest`): GitHub is the only host in v1 but sits behind the seam,
  and `PullRequest` is host-neutral, so the context says `pullRequest`.
  Host-specific extras, if they come, go in a `github` property then.
- **Exposing the working tree's files**: the checkout in a `pull_request`
  run is the merge commit, not the head (section 3), so a rule that reads
  `Package.swift` from disk sees the merged file. Steward doesn't wrap
  file reading in v1; the quickstart (4.7) documents the caveat, and
  `GitChanges` can grow a `contents(of:at:)` that reads a blob
  from either commit when a rule needs it.
