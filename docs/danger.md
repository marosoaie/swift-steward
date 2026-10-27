# Steward: a pure-Swift Danger

**Status: reviewed (plan step 4.1).** Step 4.2 built the context, and
step 4.3 the DSL, the runner, and the dry run, and step 4.4 the sticky
comment; steps 4.5–4.10 build on what this document settles. Each section ends with
a recommendation and the alternatives weighed. The maintainer answered
all ten [questions](#answered-questions) on 2026-10-26, each as
recommended (7 with a documentation requirement added), the four
step 4.2 raised in swift-steward#27 the same day, each as recommended,
the seven step 4.3 raised in swift-steward#28, also that day and as
recommended, and the four step 4.4 raised in swift-steward#29 on
2026-10-27, as recommended too. The sections reflect the answers. Claims about danger-swift, GitHub, and
SwiftPM were checked against their sources or by experiment;
[Checks](#checks) lists how.

## Decisions at a glance

| # | Topic | Recommendation | Alternatives considered |
|---|---|---|---|
| S1 | Rule shape | **Decided 2026-10-26.** `Rule`: a name plus a pure `@Sendable (Context) async throws -> [Finding]`; rules composed with a result builder; a thrown error becomes a failure of that rule | An `inout` report; a `Rule` protocol; danger-swift's global `danger` and free `warn()` |
| S2 | Context | **Paths, the dry-run placeholder, `Run`'s fields, and the activity types decided 2026-10-26.** One immutable `Context`: `pullRequest` from the event payload (no API call), `git` from the local checkout through the full model, eagerly; `String` paths in the file lists, bytes in `diff`; a placeholder pull request in a local dry run without `--pull-request`; `Run` carries the line map and the API and server URLs; `ready_for_review` joins the accepted activity types | Lazy git data; reading the PR through the API; a `github` namespace; `[DiffPath]` lists |
| S3 | Line numbers | **Decided 2026-10-26.** Head coordinates everywhere: `context.git` is `base...head`, and build-log lines are mapped from the built tree (the merge commit by default, or the head when only the head is checked out) to the head before matching; Steward leaves `safe.directory` to the workflow | Merge coordinates throughout; build the head instead; two diffs |
| S4 | Report | **Generator decided 2026-10-26:** `Steward <version>`, the version the CLI prints. A `Codable` `Report` of findings (not rendered text), versioned, with fixed snake-case keys; v1 runs evaluate → report → post in one process; a later fork flow posts from `workflow_run` and takes the target from its trusted payload | Pre-rendered Markdown in the artifact; `pull_request_target` |
| S5 | Summary comment | **Clean case, markers, the headline's notes, and the size budget's step decided 2026-10-26; the author option and the budget's API 2026-10-27.** The 3.5 marker on the first line, only the token's own comments (`--summary-author` names another account); danger-style tables per kind with head-commit links; 65,536 UTF-8 bytes, cut from the end, everything in the job summary or the report artifact; "all clear" in place of a resolved summary; skip posting when the head moved | Keyed markers in v1; lists instead of tables; deleting or always posting when clean |
| S6 | Posting failures | **Decided 2026-10-26; the wait's API and the fork notice 2026-10-27.** Findings alone decide the exit code (0 clean, 1 failures, 2 Steward broken); a posting failure is a warning annotation plus the job summary, one retry for transient errors, waiting as long as `retryAfter` says, and `--fail-on-post-error` opts into failing; on fork pull requests the rules run and posting is skipped with a notice | Always fail; fail on configuration errors only; refusing to run on forks |
| S7 | danger-swift mapping | Same vocabulary, reshaped: static factories for the four kinds, `context.git` and `context.pullRequest` for `danger.git` and `danger.github.pullRequest`, packages instead of `fileImport`/inline deps; no suggestions, reviews, or API access in v1 | Source compatibility (ruled out by the plan) |
| S8 | Packaging and the Action | `Steward` and `StewardTesting` products; the user's `Dangerfile/` is an ordinary package beside theirs; **decided 2026-10-26:** the Action in a separate `steward-action` repository (decision 3), both products in 4.6, and `Steward` re-exports `GitDiffKit` and `PullRequestHosting` | `action.yml` at swift-steward's root with a moving `v1` tag |

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

**Decided (A),** as recommended (question 1, answered 2026-10-26):

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
    public static func markdown(_ text: String, at location: Location? = nil) -> Finding
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
`for`, and arrays of rules (a shared helper can add several at once). The
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
in the report. The maintainer chose this shape and this error and order
behavior on 2026-10-26 (questions 1 and 2). **Decided 2026-10-26
(question 20):** `markdown(_:at:)` takes a location like the other three
factories, since section 7 maps danger-swift's `markdown(_:file:line:)`
to it.

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
    public var lineMap: LineMap           // built-tree lines to head lines (section 3)
    public var apiURL: URL                // GITHUB_API_URL, for GitHub Enterprise
    public var serverURL: URL             // GITHUB_SERVER_URL, for links
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
  events only (`opened`, `synchronize`, `reopened`, plus `edited` and
  `ready_for_review` if the workflow lists them, for title and body rules
  and for draft rules) and refuses any other event or activity type with
  a clear message. That includes `pull_request_target`, which runs
  in the context of the default branch, so its checkout isn't the pull
  request at all. **Decided 2026-10-26 (question 12):** `ready_for_review`
  joins the list; `labeled` and the other activity types stay refused
  until someone needs them.
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
  Enterprise without configuration. **Decided 2026-10-26 (question 11):**
  `Run` carries the line map and both URLs, as step 4.2 built it.

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
are rare enough to document instead. **Decided 2026-10-26 (question 9):**
`String` in the conveniences and `Location`, `DiffPath` in `diff`.

**Locally** (the dry run, 4.3), the git half works as in CI: the head
is `HEAD`, and the base is `--base <ref>` (default: the remote's default
branch). The pull request half has no source, because there is no event
payload. With `--pull-request <n>` and a token, Steward reads the real
pull request through `pulls/get`. Without them, for example before the
pull request exists, something has to stand in for `context.pullRequest`:

| Option | `context.pullRequest` in a dry run without `--pull-request` | Cost |
|---|---|---|
| **A. Placeholder** | Built from the head commit: its subject as the title, its body as the description, the git user as the author, number 0, no labels, sizes from the local diff. The printed summary says it's a placeholder, and a rule can check `context.run.mode` | A rule about labels or the description may report findings locally that the real pull request wouldn't get |
| B. Optional | `PullRequest?`, `nil` in a dry run | Every rule that reads it has to unwrap it, although it's never `nil` in CI |
| C. Required | The dry run refuses to start | Local runs need the network, a token, and an already-open pull request |

**Decided (A),** as recommended (question 6, answered 2026-10-26), so
rules stay simple and a dry run works on a branch nobody has pushed yet.

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

## 3. Which tree line numbers refer to (S3)

Two trees are in play in every `pull_request` run:

- **The pull request view.** GitHub's Files changed tab shows the
  three-dot diff `base...head`: from the merge base of the two branches
  to the head commit. Its new-side line numbers are the head commit's,
  and so are the `#L` anchors of a blob link at the head SHA.
- **The merge commit.** `actions/checkout` checks out `GITHUB_SHA`, the
  test merge GitHub keeps at `refs/pull/N/merge`, whose parents are the
  base branch's tip and the head. Whatever the workflow builds and lints
  is that tree, so build logs carry its line numbers.

The two agree on a file unless the base branch changed that file *above*
the pull request's edits after the branch was cut. Then every line below
the base's change shifts in the merge tree. The repositories' own history
shows how it plays out. Of the merged pull requests in both repositories,
six merged after their base had moved, and two of those touched a file
the base had also changed (`AGENTS.md`, swift-steward#20 and
git-diff-parser#2); both times the base's edit sat below the pull
request's, so the numbers agreed. Replaying the same two library pull
requests in the other order shows the shift. Had git-diff-parser#2 (three
lines added near the top of `AGENTS.md`, two more lower down) landed
before git-diff-parser#1:

| | Hunk for `AGENTS.md` | The added line `**Doc comments on public API; …**` |
|---|---|---|
| Pull request view, `ce8bbbf...b81007f` | `@@ -91,3 +91,8 @@` | line 91 |
| Merge tree CI would build (`git merge-tree` of `ce6e916` and `b81007f`) | `@@ -96,3 +96,8 @@` | line 96 |

A linter run in that job would report line 96; the reviewer sees the line
as 91, and a link to `blob/b81007f/AGENTS.md#L96` would land five lines
off. [Checks](#checks) has the commands.

`danger.git` has to match what the reviewer sees, so `context.git` is the
pull request view: `git diff` from `merge-base(base.sha, head.sha)` to
`head.sha`, both SHAs from the event payload. Because it's three-dot, the
base moving again after the event doesn't change it. The open part is the
diagnostics.

| Option | `context.git` | Diagnostics matched in | Links point at |
|---|---|---|---|
| **A. Head coordinates, logs translated** | `base...head` | head coordinates, after mapping each log line from the built tree to the head | `blob/<head>` |
| B. Merge coordinates throughout | `base-tip...merge`, as `pr.yml` diffs today | merge coordinates | `blob/<merge>`, which GitHub recomputes and replaces on every push to either branch |
| C. Build the head instead | `base...head` | head coordinates; nothing to map | `blob/<head>` |
| D. Two diffs | `base...head` | merge coordinates against `base-tip...merge`, findings mapped to the head afterwards | `blob/<head>` |

**Decided (A),** as recommended (question 3, answered 2026-10-26).
Everything a rule or a reader sees is in head coordinates, and the one tree that differs, the built one, is mapped once,
at the edge:

- `Run.builtCommit` names the commit the logs came from: `GITHUB_SHA` by
  default, or the head itself, or whatever a log source declares
  (`.xcodebuild("build.log", builtAt: sha)`) when the build ran in
  another job with another checkout. **Decided 2026-10-26 (question
  13):** a workflow that checks out `head.sha` has no merge commit, so
  when the checkout lacks `GITHUB_SHA` and `HEAD` is the pull request's
  head commit, the built commit is the head, and the map is the
  identity. With `HEAD` anywhere else, or unborn, Steward can't tell
  which tree the logs came from, so it fails, saying that neither the
  merge commit nor the head is checked out. A checkout that has
  `GITHUB_SHA` keeps it as the built commit whatever `HEAD` is: the
  fallback is only for a missing one.
- When the built commit is the head, the mapping is the identity and
  nothing runs. Otherwise Steward runs `git diff -U0 -M <head> <built>`
  over the whole tree, keeps the files whose head-side path the pull
  request touched, and turns their hunks into a monotonic map from
  built-tree lines to head lines: a line outside every hunk shifts by the
  hunks above it; a line inside one, one that the base changed or the
  merge rewrote, has no head counterpart. A path the base renamed maps
  back through the rename. The diff can't be limited to the pull
  request's paths with a pathspec: git detects renames only among the
  paths a pathspec selects, so a file the base renamed would show up as
  deleted, and every diagnostic in it would be dropped.
- The built-in rule (4.5) maps each diagnostic, drops the ones with no
  head counterpart (they can't be on the pull request's changes, which
  exist in the head), and matches the rest against `context.git` with
  `DiagnosticMatcher`. Dropped diagnostics are counted in the log.

Why not the others: B makes the summary disagree with the Files changed
tab, and its links rot as soon as the merge ref moves. B is also what
`pr.yml` does today: its `filter` step diffs `origin/<base>...HEAD` on the
merge commit. The check runs it annotates sit on the head commit (this
repository's `pull_request` runs report the head SHA), so in the shifted
case its annotations probably land on the wrong lines; GitHub doesn't
document how it places them. 4.9 replaces that step. C is consistent
and free, and Steward supports it (it's the identity case), but the build
then stops testing what will actually merge, and the build job is the
user's to configure, not Steward's. D gives the same answers as A with
two diffs and two coordinate systems to keep straight.

Constraints this puts on the workflow:

- **History.** The mapping and the merge base need the head, the base
  tip, their merge base, and the built commit in the local repository.
  `actions/checkout`'s default depth of 1 has only the merge commit. The
  quickstart can say `fetch-depth: 0`; the composite Action (4.8) should
  fetch just what it needs (the two SHAs, with history back to their
  merge base) so large repositories don't pay for a full clone. Back to
  the merge base on every path, that is: a shallow cut the base reaches
  above a commit the pull request's commits start from can move shared
  history into `base..head`, so Steward refuses a clone with one. For a
  branch that merged the base, that means back past the branch's fork
  point, not only the last merge.
- **Conflicts.** A pull request with conflicts has no test merge commit,
  so there's no merge tree to map from; GitHub doesn't run `pull_request`
  workflows for it then (see [Checks](#checks)).
- **Deleted files.** A finding on a deleted file has a path but no head
  line; the summary shows the path without a link.
- **Ownership.** In a container job the checkout belongs to the runner's
  user, not the container's, and git refuses to read it ("dubious
  ownership"). **Decided 2026-10-26 (question 14):** Steward doesn't
  trust the directory itself, because that's git's safety check to keep.
  It fails with git's error and names the fix to run before it,
  `git config --global --add safe.directory "$GITHUB_WORKSPACE"`. The
  Action (4.8) sets it for the workspace, and the quickstart (4.7) and
  the docs (4.10) cover workflows without the Action.

## 4. The report (S4)

Evaluating rules and posting their results are separate stages joined by
one value:

```swift
/// What one run of a Dangerfile found, ready to render or to hand to a
/// later, privileged job.
public struct Report: Sendable, Hashable, Codable {
    public var schemaVersion: Int     // 1; bumped on any breaking change
    public var repository: String     // owner/name of the base repository
    public var pullRequest: Int
    public var headCommit: String     // the SHA the findings describe
    public var findings: [Finding]    // rule order, then the order each rule returned them
    public var generator: String      // e.g. "Steward 1.0.0", for the log

    public var hasFailures: Bool { get }
}
```

**Decided 2026-10-26 (question 18):** `generator` is `Steward <version>`,
the version `steward --version` prints. Both read one constant,
`Release.version` in the package's internal `StewardVersion` target, so a
release still bumps the version in one place.

The JSON keys are a wire contract, so they're fixed with `CodingKeys`
rather than taken from property names: `schema_version`, `repository`,
`pull_request`, `head_commit`, `findings`, `generator`, and in a finding
`kind`, `text`, `location` (`path`, `line`), and `rule`. Snake case
matches the GitHub payloads the same workflows read. The encoder sorts
keys, so one report always encodes to the same bytes. Decoding fails on
an unknown `kind` or a newer `schema_version` rather than guessing.

In v1 the stages run in one process: rules → `Report` → summary text →
`PullRequestHost`, and `--report <path>` also writes the report to a
file. The point of the seam is the fork flow in the backlog. A fork's
`pull_request` run gets a read-only token, so it can't post. The standard
answer is a second workflow on `workflow_run`, which runs from the
default branch with a write token after the first one completes, and can
download its artifacts:

1. The unprivileged `pull_request` job evaluates the rules, writes
   `report.json`, uploads it as an artifact, and exits with the findings'
   status. It needs no token and posts nothing.
2. The privileged `workflow_run` job downloads the artifact, renders the
   summary, and posts it. It never checks out or runs the pull request's
   code (actions/checkout v7 refuses to check out fork code under
   `workflow_run` by default anyway).

GitHub's documentation says to treat such artifacts as untrusted, and the
report is exactly that: a fork's author controls every byte. So the
design commits to these rules now, while the format is new:

- **The report is data, not presentation.** It carries findings, not
  rendered Markdown, so the privileged side owns the format, the marker,
  the size limit, and escaping. A pre-rendered comment in the artifact was
  weighed: simpler, but the trusted job would post attacker-chosen text
  verbatim, and the evaluating and posting sides could never differ in
  version.
- **Where to post never comes from the report.** The poster finds the
  pull request from the trusted `workflow_run` payload: the triggering
  run's head repository and head SHA, looked up through the API, because
  the payload's own `pull_requests` list can be empty for runs from forks
  (actions/runner#3444). It accepts exactly one open pull request whose
  head is that SHA in that repository, refuses a missing or ambiguous
  match, and refuses a report whose `repository` or `head_commit`
  disagrees. Otherwise a fork could aim the bot at any pull request.
- **Size and content are bounded on the trusted side**: a cap on the
  number of findings and on each text before rendering, and the summary's
  own size limit (section 5).

`pull_request_target` was the other way to get a write token for forks.
It runs with secrets in the base repository's context, GitHub warns
against running the pull request's code in it, and GitHub has announced a
default policy that blocks it in public repositories (evaluation now,
enforcement from 2026-12-02), so it isn't a path to build on.

*Trade-off:* a versioned, public JSON format is one more contract to keep
stable. It stays small (six fields and a finding), and `schema_version`
lets the two sides of a fork flow refuse each other clearly when they
drift.

## 5. The summary comment (S5)

### Finding it: the marker

Step 3.5 settled the mechanism: the summary is the comment whose first
line is exactly `<!-- steward-summary -->`, an HTML comment GitHub
doesn't render. `GitHubHost` adds the line when posting and strips it
when reading, so the renderer never sees it. Two choices are left:

- **Whose comments count.** Steward passes `summaryAuthor`, so a comment
  only counts if the token's own account wrote it: `github-actions[bot]`
  by default, and `--summary-author <login>` for a PAT or a GitHub App
  token (the login compared ignoring case). **Decided 2026-10-27
  (question 22):** the Action (4.8) exposes the option as an input.
  danger-js has no such filter: any comment containing its `DangerID` marker and
  "Generated by" is fair game for it to overwrite or delete.
- **One summary or several.** danger-js keys its marker
  (`DangerID: danger-id-<id>;`, `--id` to change it) so several Danger
  runs on one pull request keep separate comments. v1 has one Dangerfile
  per repository, so it has one marker. If several are wanted later, the
  keyed form `<!-- steward-summary:<id> -->` is reserved for them, and
  plain `steward-summary` stays the default id; the marker is internal
  to `GitHubHost`, so adding keys breaks nothing. **Decided 2026-10-26
  (question 7): not in v1.** Steward's user documentation (the
  quickstart, 4.7, and the docs, 4.10) says plainly that several
  Dangerfiles posting to one pull request are unsupported: their runs
  would find the same summary and overwrite each other's.

When `summaryComments(onPullRequest:)` returns more than one (two runs
raced to create one), the runner updates the oldest and deletes the rest,
as danger-js does. It updates first, so a run that fails part-way still
leaves the current summary; a duplicate it couldn't delete is collapsed
by the next run. If the oldest was deleted since it was listed
(`notFound`), the runner posts a new one instead. Comments are listed a
hundred a page, through every page.

### What it says

Failures, warnings, and messages each get a table, in that order and only
when non-empty, then the `markdown` findings as they are, then a footer:

```markdown
**2 failures, 1 warning** on 4c95447

| | Failures |
|---|---|
| :no_entry_sign: | Write Legacy.m in Swift.<br>[`Sources/Legacy.m`](https://github.com/o/r/blob/4c95447…/Sources/Legacy.m) |
| :no_entry_sign: | Unused variable 'count'.<br>[`Sources/Counter.swift:12`](https://github.com/o/r/blob/4c95447…/Sources/Counter.swift#L12) |

| | Warnings |
|---|---|
| :warning: | Add a CHANGELOG entry. |

<sub>Steward 1.0.0 · [workflow run](https://github.com/o/r/actions/runs/123) · 4c95447</sub>
```

- **The layout and icons follow danger-js** (`:no_entry_sign:`,
  `:warning:`, `:book:`), so a team migrating from danger-swift
  recognizes the comment. Within a table, findings keep rule order.
- **Locations link to the head commit**: `blob/<head SHA>/<path>#L<n>` on
  `GITHUB_SERVER_URL`, with each path segment percent-encoded, which
  section 3 makes correct. Deleted files show their path without a link.
- **Table cells can't hold block Markdown**, so the renderer turns line
  breaks into `<br>` and escapes `|`. A rule that needs a list, a code
  block, or its own table returns a `markdown` finding instead.
- **Finding text is Markdown by contract**, and rules may mention people
  on purpose. Text from tools is plain text, so the built-in rule escapes
  it (Markdown punctuation, and `@` so a compiler message can't ping
  anyone) before it becomes a finding.
- **The headline counts everything**, even when the body is cut short.
  `markdown` findings count as notes:
  `**1 failure, 2 warnings, 1 message, 1 note**` (decided 2026-10-26,
  question 17).

### Size

GitHub rejects a comment body over its limit with a 422 (`rejected`).
The limit isn't documented: the API's own error says "maximum is 65536
characters", and community measurements suggest a byte limit four times
that underneath. Steward budgets **65,536 UTF-8 bytes** for the whole
body, marker included. No reading of "characters" counts more of them
than there are bytes, so that budget is safe whatever the real unit is.
Over budget, the renderer cuts from the end (markdown first, then
messages, warnings, and failures, last rows first), truncates any single
text that alone exceeds the budget, and ends with "…and 312 more
findings", pointing at where all of them are. A truncated text is shown
as code, so whatever it opens, a code block or an HTML tag, can't
swallow the rest of the comment. The budget is
`PullRequestHost.maximumSummarySize`, which `GitHubHost` sets to what's
left of 65,536 bytes once the marker line is added; it's public, so
another host can state its own limit (decided 2026-10-27, question 23).
The rendering also
goes to `$GITHUB_STEP_SUMMARY`, cut the same way to what's left of 1 MiB
once earlier steps' summaries are counted: GitHub drops a larger step
summary entirely instead of truncating it. When nothing fits there, the
job summary is left out with a warning. The complete list is always in
the log, and in the report when the run writes one with `--report`, as
the Action does, uploading it as an artifact. So the comment's note
points at the job summary when everything fit there, else at the report
artifact when there is one, else at the log, and the job summary's
note at the artifact or the log. **Decided 2026-10-26 (question 21):**
the budget came with the sticky comment in step 4.4.

### When there's nothing to report

| Option | Existing summary | No summary yet |
|---|---|---|
| **A. All clear** | updated to "No findings on `<sha>`", with the footer | nothing posted |
| B. Delete (danger-js's default) | deleted | nothing posted |
| C. Always post | updated | "No findings" posted on every clean pull request |

**Decided (A),** as recommended (question 5, answered 2026-10-26).
Reviewers who saw the failures find the resolution where they saw them,
and GitHub's edit history keeps the old findings; a deleted comment just
vanishes, which reads like a glitch. A clean pull request never gets a
comment, so A adds no noise.

### Stale runs

A run for an older commit can finish after a run for a newer one and
overwrite its summary. The Action's documentation sets a `concurrency`
group per pull request with `cancel-in-progress: true`, and just before
writing, the runner re-reads the pull request (`pulls/get`, one request)
and skips posting when its head is no longer `headCommit`: a newer run
will post. The skip is logged, not an error. The re-read comes after the
summary is found and before the first write, so a clean run with
nothing to post doesn't spend the request, and again before a write's
retry, a duplicate's deletion included, since a newer run may have
posted during the pause: when the oldest summary was deleted meanwhile,
the duplicate is the newer run's summary. A run that finds its head
moved then stops, leaving the rest to the newer run.

## 6. Running, exit codes, and posting failures (S6)

### The run

`Dangerfile`'s default `main()` is the whole runner (4.3):

1. **Mode.** `GITHUB_ACTIONS=true` means a CI run; anything else is a
   dry run, which never posts, whatever the flags say.
2. **Context** (section 2) and the line map (section 3). An unsupported
   event, a missing payload, or a git failure ends the run here.
3. **Rules** (section 1), into a `Report` (section 4); `--report <path>`
   writes it out.
4. **Render** the summary (section 5): to the log and appended to
   `$GITHUB_STEP_SUMMARY` in CI (a summary that can't be written only
   warns), to standard output in a dry run.
5. **Post** through `PullRequestHost`, unless this is a dry run or the
   pull request comes from a fork (v1 checks `PullRequest.isFromFork`
   first, says why it won't post in a `::notice title=Steward::` annotation, and
   carries on, so fork contributors still get a check status and the job
   summary; decided 2026-10-26, question 10, and the notice 2026-10-27,
   question 25). Posting needs
   `GITHUB_TOKEN`; a step without it warns and sends no request.
6. **Exit.**

Options are a handful of hand-parsed flags (`--base`, `--pull-request`,
`--report`, `--fail-on-post-error`, `--summary-author`, `--help`) and
environment variables
(`GITHUB_TOKEN` and the variables Actions sets), because `Steward` is a
library and AGENTS.md keeps swift-argument-parser in the CLI target. A CI
run ignores the dry run's `--base` and `--pull-request`, with a warning:
there, the event names the pull request. The log goes to standard error,
grouped with `::group::` in Actions; text that could pass for a workflow
command, such as a finding's, is logged with commands paused
(`::stop-commands::`). The library's damage reports go there too; an
abandoned file (`.error`) becomes a `::warning::` annotation, since the
rules then saw an incomplete diff.

A dry run takes its repository, which the summary's links and
`--pull-request` need, from `GITHUB_REPOSITORY`, or else from the `origin`
remote when it's on `GITHUB_SERVER_URL`'s host, in any form git takes
(`https://`, `ssh://`, or scp-style `git@host:o/r`). Without either, the
summary shows paths without links, and `--pull-request` exits 2, asking
for the repository. An SSH host alias (`github-work:o/r`, from
`~/.ssh/config`) doesn't name the server's host, so it isn't recognized;
setting `GITHUB_REPOSITORY=o/r` covers it. Decided 2026-10-26, question
19.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | No `failure` findings. Posting succeeded, was skipped, or failed without `--fail-on-post-error` |
| 1 | At least one `failure` finding, including a rule that threw |
| 2 | Steward couldn't do its job: an unknown option, a context that couldn't be built, a `--report` that couldn't be written, a cancelled run, or posting that failed with `--fail-on-post-error` |

Exit code 2 wins over 1, since a broken run says nothing reliable about
the pull request. A dry run exits the same way, so it works as a local
pre-push check.

### When posting fails

Posting can fail for reasons that say nothing about the pull request:

| `PullRequestHostError.Kind` | Typical cause | What Steward does |
|---|---|---|
| `forbidden` | The workflow lacks `pull-requests: write`; or a Dependabot pull request, which is a same-repository branch but gets a read-only token (documented) | Warns with the fix: grant `pull-requests: write` (enough for issue comments on pull requests, per the REST docs), or skip Dependabot |
| `unauthorized` | No token, or a wrong one. A missing token is caught before any request | Warns |
| `rateLimited`, `serverError`, `network` | GitHub is busy or down; `GITHUB_TOKEN` has 1,000 requests an hour per repository | Retries once, then warns. It waits as long as GitHub asks (`retry-after`, or the primary limit's reset, which the error carries as its public `retryAfter`; decided 2026-10-27, question 24), or else a minute for a rate limit and 2 seconds for the rest; a wait over a minute isn't worth the job's time, so it warns at once, saying how long GitHub asked for |
| `notFound` on update | Someone deleted the summary since it was listed | Not a failure: creates a new one |
| `rejected` | Too long despite the budget, or GitHub's spam check | Warns |
| `malformedResponse`, `unexpectedStatus` | GitHub answered something the client doesn't understand | Warns |

"Warns" means a `::warning title=Steward::` annotation on the run that
names the error; the job summary and the report artifact, written before
posting, still hold the findings. The question is the exit code.

| Option | A posting failure… |
|---|---|
| **A. Findings decide; opt-in strictness** | never changes the exit code, unless the workflow passes `--fail-on-post-error` (an Action input) |
| B. Always fails the job | exits 2 |
| C. Fails on configuration errors only | exits 2 for `forbidden`/`unauthorized`, warns for the rest |

**Decided (A),** as recommended (question 4, answered 2026-10-26). The
check's status should answer "is this pull request acceptable?", not "was GitHub reachable?". A failing pull
request stays red without the comment, because its failures set exit 1
on their own, and its findings are in the job summary. A passing one
shouldn't turn red because of an outage, or on every Dependabot pull
request, which is what C would do: Dependabot's `forbidden` looks exactly
like a missing permission. The cost is that a missing permission goes
unnoticed except through the warning annotation on every run, so the
quickstart's workflow sets `permissions:` explicitly (new repositories
default the token to read-only), and teams that want it loud set the
flag.

## 7. From danger-swift (S7)

danger-swift 3.23.1 (the latest release, 2026-10-18) evaluates the
Dangerfile, writes its results as JSON, and hands them to danger-js,
which needs Node and does all the posting. Steward replaces both halves.
The table maps every call a Dangerfile commonly makes, read from
danger-swift's source at that tag; the migration guide (4.10) grows out
of it. `context` is the rule closure's parameter.

| danger-swift | Steward v1 | Notes |
|---|---|---|
| `let danger = Danger()` | `@main struct Checks: Dangerfile`, and each rule's `context` | No global; the runner builds the context once |
| `warn("…")`, `danger.warn("…")` | `[.warning("…")]` returned from a rule | Same for `fail` → `.failure`, `message` → `.message`, `markdown` → `.markdown` |
| `warn(message:file:line:)` (and `fail`, `message`, `markdown`) | `.warning("…", at: Location(path: file, line: line))` | Rendered as a link in the summary; inline review comments are in the backlog |
| `suggestion(code:file:line:)` | – | Needs inline review comments (backlog) |
| `danger.fails`, `.warnings`, `.messages`, `.markdowns` | – | A rule never sees other rules' findings; tests inspect what a rule returns (`StewardTesting`, 4.6) |
| `danger.git.modifiedFiles`, `.createdFiles`, `.deletedFiles` | `context.git.modifiedFiles`, `.createdFiles`, `.deletedFiles` | `[String]` in both; plus `renamedFiles` (section 2) |
| `danger.git.commits` | `context.git.commits` | Local `git log`; `subject` and `body` instead of `message`; `sha` isn't optional |
| `danger.utils.diff(forFile:sourceBranch:)` | `context.git.file(at:)` | A `DiffFile` from the full model, parsed once, against the pull request's merge base, instead of one `git diff` per call |
| `danger.utils.readFile(_:)`, `.lines(for:inFile:)` | Foundation | The working tree is the merge commit in a `pull_request` run (section 2) |
| `danger.utils.exec(_:arguments:)`, `.spawn(_:arguments:)` | Foundation's `Process` | Rules are `async throws`, so a failing tool can throw |
| `danger.utils.environment.NAME` | `ProcessInfo.processInfo.environment["NAME"]` | |
| `danger.github.pullRequest.title`, `.body`, `.number`, `.htmlUrl` | `context.pullRequest.title`, `.body`, `.number`, `.webURL` | `body` is `""` rather than `nil` when empty |
| `.pullRequest.user.login` | `context.pullRequest.author` | |
| `.pullRequest.additions`, `.deletions`, `.changedFiles`, `.commitCount` | `.additions`, `.deletions`, `.changedFiles`, `.commits` | Non-optional |
| `.pullRequest.draft`, `.state`, `.isMerged` | `.isDraft`, `.state` (`.open`, `.closed`, `.merged`) | |
| `.pullRequest.base.ref`, `.sha`, `.repo` (and `head`) | `.base.name`, `.commit`, `.repository` (and `head`) | `repository` is `owner/name` |
| `danger.github.issue.labels` | `context.pullRequest.labels` | Names only |
| `danger.github.commits` | `context.git.commits` | From git, not the API |
| `danger.github.reviews`, `.requestedReviewers` | – | Would need the API from rules; not in v1 |
| `danger.github.api` (OctoKit) | – | The host isn't exposed to rules in v1 |
| `danger.gitLab`, `.bitbucketCloud`, `.bitbucketServer` | – | GitHub only, behind the seam (backlog) |
| `SwiftLint.lint(inline: true, …)` | `Rule.diagnosticsOnChangedLines(in: [.swiftLint("swiftlint.json")])` | Reads a report the workflow already produced instead of running SwiftLint, and keeps only changed lines (4.5); also xcodebuild, SwiftFormat, Sonar |
| `// fileImport: Other.swift` | Another file in the `Dangerfile` target | It's an ordinary package |
| `import X // package: <url>`, or a `DangerDeps` library product | `dependencies:` in `Dangerfile/Package.swift` | |
| `danger-swift ci` | The composite Action (4.8), which runs `swift run` in `Dangerfile/` | |
| `danger-swift local` | `swift run` in `Dangerfile/` outside Actions: a dry run (`--base`, `--pull-request`) | |
| `danger-swift pr <url>` | – | Remote dry run is in the backlog |
| `danger-swift edit` | Open `Dangerfile/Package.swift` in Xcode | |
| `DANGER_GITHUB_API_TOKEN` | `GITHUB_TOKEN` | danger-js reads either |

The deliberate departures, in one place: no global `danger` and no
global result lists; findings returned, not reported; paths in
`Location` rather than `file:`/`line:` arguments; pull request data from
the event, not the API; nothing that needs inline comments or API access
from rules. They follow from the plan's decisions (value types, no
globals, one summary comment) rather than from taste, and the migration
guide says so.

## 8. Packaging, rule tests, and the Action (S8)

### Products

swift-steward gains two library products:

- **`Steward`**: `Rule`, `Finding`, `Location`, `Context` and its parts,
  `Report`, the `Dangerfile` protocol and its runner, the summary
  renderer, and the built-in diagnostics rule. It depends on `GitDiffKit`
  (the full model, so library 0.2.0 and macOS 26), `BuildLogKit`,
  `DiffDiagnostics`, `PullRequestHosting`, and `GitHubAPI`. Generated
  types stay out of its public API, as they do out of the seam's.
  **Decided 2026-10-26 (question 16):** it re-exports `GitDiffKit` and
  `PullRequestHosting` with `@_exported import`, so a Dangerfile needs
  only `import Steward`. Under `MemberImportVisibility`, a member such as
  `context.pullRequest.title` is visible only in a file that imports its
  module, Swift has no supported way to re-export one, and
  `PullRequestHosting` isn't a product, so a Dangerfile couldn't import it
  itself.
- **`StewardTesting`** (4.6): builds a `Context` from fixtures (a diff
  as text, which the full model parses exactly as in a real run; a
  `PullRequest` with defaults for every field; commits) and a fake
  `PullRequestHost` that records what the runner would post. A rule the
  tests need by name is a static property (`static let changelog =
  Rule("Changelog") { … }`, listed in `rules` as `changelog`), and the
  test target reaches it with `@testable import Dangerfile`. A rule test
  is then one call:

  ```swift
  @Test("a pull request without a changelog entry gets a warning")
  func missingChangelog() async throws {
      let context = try Context.fixture(diff: """
          diff --git a/Sources/App.swift b/Sources/App.swift
          …
          """)
      let findings = try await Checks.changelog.evaluate(context)
      #expect(findings == [.warning("Add a CHANGELOG entry.")])
  }
  ```

**Decided 2026-10-26 (question 15):** both products arrive in step 4.6,
together; until then, `Steward` is a target the end-to-end tests' fixture
Dangerfile builds against.

A user's `Dangerfile/` is an ordinary package: an executable target that
depends on `Steward`, a test target that depends on `StewardTesting`, and
any other dependencies the rules need. It lives beside the user's own
package, not inside it, so it never joins the app's build graph, and
`swift test --package-path Dangerfile` runs the rule tests. The template
(4.7) ships exactly that.

### The Action (decision 3, decided 2026-10-26)

The composite Action (4.8) is glue: install a Swift toolchain on Ubuntu,
restore a cache of `Dangerfile/.build` keyed on `Package.resolved`, the
Swift version, and the OS, fetch the history section 3 needs, and run
`swift run --package-path Dangerfile`. It needs `contents: read` and
`pull-requests: write` (the REST docs list either `issues: write` or
`pull-requests: write` as enough to create, update, and delete issue
comments, and an Actions token is an installation token). Where it lives
was plan decision 3:

| | A. `action.yml` at swift-steward's root | B. A separate `marosoaie/steward-action` |
|---|---|---|
| Usage | `uses: marosoaie/swift-steward@v1` | `uses: marosoaie/steward-action@v1` |
| Major tag | A moving `v1` beside the package's semver tags. SwiftPM ignores a bare `v1` (checked; see [Checks](#checks)), but swift-steward already has `v1.0.0`–`v1.0.2` and `v2.0.0`, so `@v1` would name neither | The Action's own `v1`, moved on each release as GitHub recommends, meaning only "these inputs" |
| Marketplace | Not listable: GitHub asks that a listed repository hold only the action's metadata, code, and the files it needs | Listable |
| Versions | One release covers both | Independent. The Action doesn't pin Steward anyway; each Dangerfile's `Package.resolved` does |
| Upkeep | One repository | One more repository, with its own ruleset and a CI job that runs the Action against a fixture Dangerfile |

**Decided (B),** as recommended (question 8, answered 2026-10-26). The
tag clash alone decides it: a moving `v1` in
a repository whose `v1.0.x` tags mean something else would confuse
everyone, and keeping the Action's major in step with the package's means
a breaking change to a Swift API forces a new Action major for unchanged
inputs. A Marketplace listing helps the launch (5.3). The SwiftPM check
still constrains swift-steward's own tags: a two-part tag such as `v1.1`
is read as version 1.1.0, so the package must never get a moving minor
tag.

## What the later steps take from this

| Step | Builds on |
|---|---|
| 4.2 Context | Section 2 (sources, event types, pinned git options) and section 3 (merge base, built commit, the line map, the history it needs) |
| 4.3 Runner and DSL | Section 1 (`Rule`, `Finding`, `Dangerfile`, the builder, thrown errors) and section 6 (stages, flags, exit codes, the dry run) |
| 4.4 Sticky comment | Section 5 (marker and author, duplicates, format, size, the clean case, stale runs) and section 6 (posting failures) |
| 4.5 Built-in rule | Section 3 (mapping log lines to the head, dropping unmapped ones) and section 5 (escaping tool output) |
| 4.6 `StewardTesting` | Section 8 (fixtures, the fake host) and section 1 (rules as values) |
| 4.7 Template and quickstart | Section 8 (the package's layout), section 2 (the merge-tree caveat, `edited` and `ready_for_review` events), section 6 (`permissions:`), section 5 (several Dangerfiles per pull request are unsupported), section 3 (`safe.directory` in container jobs without the Action) |
| 4.8 Action | Section 8 (decision 3: a separate `steward-action` repository), section 3 (fetching history, `safe.directory` for the workspace), section 5 (the `concurrency` group) |
| 4.9 Dogfood | Section 3 (`pr.yml`'s `filter` step works in merge coordinates) |
| 4.10 Docs | Section 7 (the mapping table, the start of the migration guide), section 5 (several Dangerfiles per pull request are unsupported), and section 3 (`safe.directory` in container jobs without the Action) |
| Backlog: fork pull requests | Section 4 (the report and the rules for an untrusted one) |

## Answered questions

The maintainer answered all ten on 2026-10-26, the four that step 4.2
raised in swift-steward#27 (numbered on from 11) the same day, and the
seven that step 4.3 raised in swift-steward#28 (numbered on from 15) that
day too, and the four that step 4.4 raised in swift-steward#29 (numbered
on from 22) on 2026-10-27. The sections refer to them by number, and each
section above already reflects its answer.

1. **Rule shape (S1). Answered 2026-10-26: pure closures** ("pure
   closures"). Rules are pure `(Context) async throws -> [Finding]`
   closures composed with a result builder, not an `inout` report.
2. **Broken rules and order (S1). Answered 2026-10-26: yes to both**
   ("yes and yes"). A rule that throws becomes a failure of that rule
   while the others still run, and rules run one at a time in
   declaration order.
3. **Line numbers (S3). Answered 2026-10-26: head coordinates** ("head
   indeed"). Everything is in head coordinates, and build-log lines are
   mapped from the built tree (the merge commit by default) before
   matching.
4. **Posting failures (S6). Answered 2026-10-26: findings decide**
   ("leave it to the findings by default"). A failed post leaves the exit
   code to the findings and warns; `--fail-on-post-error` opts into
   failing the job.
5. **Nothing to report (S5). Answered 2026-10-26: all clear** ("all
   clear"). An existing summary is updated to "all clear"; a clean pull
   request without one gets none.
6. **Pull request data in a local dry run (S2). Answered 2026-10-26:
   the placeholder** ("A, the placeholder built from the head commit").
   With `--pull-request <n>` and a token, a dry run reads the real pull
   request through `pulls/get`. Without them, `context.pullRequest` is
   built from the head commit (subject as title, body as description,
   git user as author, no labels, sizes from the local diff), and the
   printed summary says it's a placeholder.
7. **Several Dangerfiles per pull request (S5). Answered 2026-10-26:
   not in v1, and documented as unsupported** ("not in v1, but make a
   note of it that it's unsupported, in the docs"). One marker per pull
   request; the keyed syntax stays reserved, and the quickstart (4.7) and
   the docs (4.10) say that several Dangerfiles per pull request are
   unsupported.
8. **Where the Action lives (S8, plan decision 3). Answered 2026-10-26:
   a separate repository** ("separate repo indeed"), `steward-action`,
   with its own moving `v1` tag.
9. **Paths in the DSL (S2). Answered 2026-10-26: `String`, as
   recommended** ("recommended option"). The file lists and `Location`
   use `String`, decoded lossily from the model's `DiffPath` bytes;
   rules that must be exact use `DiffPath` in `diff`.
10. **Fork pull requests in v1 (S6). Answered 2026-10-26: evaluate and
    skip posting** ("evaluate and skip posting"). The rules run, posting
    is skipped with a notice, and the exit code follows the findings,
    until the fork flow (S4) lands.
11. **`Run`'s extra fields (S2). Answered 2026-10-26: keep them** ("as
    you recommended", for all four of #27's questions). `Run` carries
    `lineMap`, `apiURL`, and `serverURL` beside the three fields this
    document first sketched.
12. **Activity types (S2). Answered 2026-10-26: add `ready_for_review`.**
    It joins `opened`, `synchronize`, `reopened`, and `edited`; `labeled`
    and the others stay refused until someone needs them.
13. **A checkout without the merge commit (S3). Answered 2026-10-26: fall
    back to `HEAD`, only when it's the head.** When the checkout lacks
    `GITHUB_SHA` and `HEAD` is the pull request's head commit, the head is
    the built commit and the line map is the identity. Otherwise the
    context fails with `missingCommit(.built)`, whose message says that
    neither the merge commit nor the head is checked out.
14. **Container jobs (S3). Answered 2026-10-26: Steward doesn't set
    `safe.directory`.** It's a git safety check. The `gitFailed` error
    names the fix,
    `git config --global --add safe.directory "$GITHUB_WORKSPACE"`; the
    Action (4.8) sets it for the workspace, and the quickstart (4.7) and
    the docs (4.10) cover workflows without the Action. `pr.yml`'s Linux
    job keeps setting it.
15. **When `Steward` becomes a product (S8). Answered 2026-10-26: in 4.6,
    with `StewardTesting`** ("as you recommended", for all seven of #28's
    questions). Step 4.3 adds no product.
16. **Re-exports (S8). Answered 2026-10-26: yes.** `Steward` re-exports
    `GitDiffKit` and `PullRequestHosting` with `@_exported import`, so a
    Dangerfile needs only `import Steward`, with `MemberImportVisibility`
    on or off. Under that feature there's no supported alternative, and
    `PullRequestHosting` isn't a product.
17. **Markdown findings in the headline (S5). Answered 2026-10-26: notes,
    as they are.** The headline counts them as notes:
    `**1 failure, 2 warnings, 1 message, 1 note**`.
18. **The generator's version (S4). Answered 2026-10-26: `Steward
    <version>`.** `Report.generator` names the release `steward --version`
    prints. Both read `Release.version` in the internal `StewardVersion`
    target, so a release still bumps one constant, which AGENTS.md's
    release note names.
19. **Dry-run repository discovery (S6). Answered 2026-10-26: as it is.**
    `GITHUB_REPOSITORY`, or else an `origin` remote on
    `GITHUB_SERVER_URL`'s host. An SSH host alias isn't recognized, and
    setting `GITHUB_REPOSITORY` covers it, as section 6 and the dry run's
    declaration say.
20. **A location for `markdown` (S1, S7). Answered 2026-10-26: accepted.**
    `markdown(_:at:)` takes a location like the other three factories, as
    section 7's mapping of danger-swift's `markdown(_:file:line:)` needs.
21. **The size budget (S5). Answered 2026-10-26: step 4.4's.** The
    65,536-byte cut comes with the sticky comment; until then, the job
    summary isn't cut. (Step 4.4 built both cuts.)
22. **The summary's author (S5). Answered 2026-10-27: `--summary-author
    <login>`** ("ok, go with the recommendations", for all four of #29's
    questions). Only comments by that account count as the summary; the
    default is `github-actions[bot]`, the login is compared ignoring case,
    and the Action (4.8) exposes it as an input for a PAT or a GitHub App
    token.
23. **The comment's budget (S5). Answered 2026-10-27: public API.**
    `PullRequestHost.maximumSummarySize` is the byte budget the renderer
    cuts to. `GitHubHost` sets it to what's left of 65,536 bytes once the
    marker line is added, and another host would state its own.
24. **How long GitHub asks to wait (S6). Answered 2026-10-27: public
    API.** `PullRequestHostError.retryAfter`, set for some `rateLimited`
    and `serverError` errors, is the wait from `retry-after` or the
    primary limit's reset. The retry honors it up to a minute and warns
    without retrying past that.
25. **The fork skip (S6). Answered 2026-10-27: a notice.** A fork pull
    request's skipped post is a `::notice title=Steward::` annotation, not
    a warning: nothing is wrong, and a warning on every fork pull request
    would teach people to ignore Steward's warnings.

## Checks

How the factual claims were verified (2026-10-25/26):

- **danger-swift and danger-js**, read from source: danger-swift at tag
  `3.23.1` (`Sources/Danger/GitDSL.swift`, `Report.swift`,
  `DangerUtils.swift`, `GitHubDSL.swift`, `Plugins/SwiftLint/SwiftLint.swift`,
  the runner's `RunDangerJS.swift`), danger-js at `14.0.6`
  (`runner/templates/githubIssueTemplate.ts`, `runner/Executor.ts`,
  `platforms/github/comms/issueCommenter.ts`, `platforms/GitHub.ts`).
  `Git`'s properties, `DangerUtils`' signatures, the empty-results
  deletion (`DANGER_SKIP_WHEN_EMPTY`, `deleteMainComment`), and the token
  variables were re-read directly after a subagent's survey.
- **GitHub**, from docs.github.com: `per_page` up to 100 and the `link`
  header (REST pagination); read-only tokens for fork and Dependabot
  pull requests (events that trigger workflows; Dependabot on Actions);
  `GITHUB_SHA` and `GITHUB_REF` for `pull_request`, and checkout of the
  merge commit; no `pull_request` runs while a pull request has conflicts
  (quote checked directly); three-dot diffs in pull requests (comparing
  branches); either `issues: write` or `pull-requests: write` for issue
  comments (REST issue comments); 1 MiB per step and 20 job summaries per
  job (workflow commands, checked directly); 10 warning and 10 error
  annotations per step (checks API); `pull_request_target` running in the
  default branch's context (checked directly), and its announced default
  block for public repositories; `workflow_run` artifacts as untrusted
  data; read-only default tokens for new repositories; 1,000 requests an
  hour for `GITHUB_TOKEN`; Marketplace repositories holding only the
  action; moving major tags (managing custom actions). The comment limit
  isn't documented: "maximum is 65536 characters" is the API's error
  text, and the byte limit underneath comes from community measurements
  (github.com/orgs/community/discussions/27190), hence the byte budget.
  This repository's last three `pull_request` runs report the branch tip
  as their head SHA (for example run 40203970914 on `d40497b`), not the
  merge commit.
- **Line numbers**, on both repositories' history: every merge commit
  `M` on `main` whose base had moved (`merge-base(M^1, M^2) != M^1`; six
  of them), with the files both sides changed. Two shared a file, and in
  both the base's edit was below the pull request's. The shifted case
  replays git-diff-parser#1 onto #2:

  ```sh
  # in git-diff-parser; ce8bbbf: fork point; b81007f: #1's head; ce6e916: #2's head
  git diff -U0 ce8bbbf...b81007f -- AGENTS.md            # @@ -91,3 +91,8 @@
  tree=$(git merge-tree --write-tree ce6e916 b81007f)
  git diff -U0 ce6e916 "$tree" -- AGENTS.md              # @@ -96,3 +96,8 @@
  ```

- **Renames under a pathspec**, by experiment: in a scratch repository
  where one commit renames `A.txt` to `B.txt`, `git diff -M --name-status
  HEAD~1 HEAD -- A.txt` reports `D A.txt`, and the same diff without the
  pathspec reports `R100 A.txt B.txt` (section 3's mapping).
- **SwiftPM and a moving tag**, by experiment under Swift 6.4: a scratch
  library tagged `1.0.0` on one commit and `v1` on the next resolves
  `from: "1.0.0"` to `1.0.0` on the first commit (the bare `v1` is
  ignored); with only `v1`, resolution fails; adding `v1.1` on the second
  commit makes it resolve to version 1.1.0.
- **The rule-shape example**: section 1's two hand-written rules, the
  builder, and stub types type-check with `swiftc -swift-version 6
  -typecheck` under Swift 6.4.
