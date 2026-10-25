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
| S3 | Line numbers | Head coordinates everywhere: `context.git` is `base...head`, and build-log lines are mapped from the built tree (the merge commit by default) to the head before matching | Merge coordinates throughout; build the head instead; two diffs |
| S4 | Report | A `Codable` `Report` of findings (not rendered text), versioned, with fixed snake-case keys; v1 runs evaluate → report → post in one process; a later fork flow posts from `workflow_run` and takes the target from its trusted payload | Pre-rendered Markdown in the artifact; `pull_request_target` |
| S5 | Summary comment | The 3.5 marker on the first line, only the token's own comments; danger-style tables per kind with head-commit links; 65,536 UTF-8 bytes, cut from the end, full text in the job summary; "all clear" in place of a resolved summary; skip posting when the head moved | Keyed markers in v1; lists instead of tables; deleting or always posting when clean |

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
  with a clear message. That includes `pull_request_target`, which runs
  in the context of the default branch, so its checkout isn't the pull
  request at all.
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

**Recommendation (A).** Everything a rule or a reader sees is in head
coordinates, and the one tree that differs, the built one, is mapped once,
at the edge:

- `Run.builtCommit` names the commit the logs came from: `GITHUB_SHA` by
  default, or the head itself, or whatever a log source declares
  (`.xcodebuild("build.log", builtAt: sha)`) when the build ran in
  another job with another checkout.
- When the built commit is the head, the mapping is the identity and
  nothing runs. Otherwise Steward runs `git diff -U0 -M <head> <built>`
  over the pull request's files and turns its hunks into a monotonic map
  from built-tree lines to head lines: a line outside every hunk shifts by
  the hunks above it; a line inside one, one that the base changed or the
  merge rewrote, has no head counterpart. A path the base renamed maps
  back through the rename.
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
  merge base) so large repositories don't pay for a full clone.
- **Conflicts.** A pull request with conflicts has no test merge commit,
  so there's no merge tree to map from; GitHub doesn't run `pull_request`
  workflows for it then (see [Checks](#checks)).
- **Deleted files.** A finding on a deleted file has a path but no head
  line; the summary shows the path without a link.

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
- **Where to post never comes from the report.** The poster takes the
  repository and the pull request from the trusted `workflow_run`
  payload and its head SHA, and refuses a report whose `repository` or
  `head_commit` disagrees. Otherwise a fork could aim the bot at any pull
  request.
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
  by default, configurable for a PAT or a GitHub App token. danger-js has
  no such filter: any comment containing its `DangerID` marker and
  "Generated by" is fair game for it to overwrite or delete.
- **One summary or several.** danger-js keys its marker
  (`DangerID: danger-id-<id>;`, `--id` to change it) so several Danger
  runs on one pull request keep separate comments. v1 has one Dangerfile
  per repository, so it has one marker. If several are wanted later, the
  keyed form `<!-- steward-summary:<id> -->` is reserved for them, and
  plain `steward-summary` stays the default id; the marker is internal
  to `GitHubHost`, so adding keys breaks nothing. Open question 7 asks
  whether v1 needs it.

When `summaryComments(onPullRequest:)` returns more than one (two runs
raced to create one), the runner updates the oldest and deletes the rest,
as danger-js does.

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

### Size

GitHub rejects a comment body over its limit with a 422 (`rejected`).
The limit isn't documented: the API's own error says "maximum is 65536
characters", and community measurements suggest a byte limit four times
that underneath. Steward budgets **65,536 UTF-8 bytes** for the whole
body, marker included. No reading of "characters" counts more of them
than there are bytes, so that budget is safe whatever the real unit is.
Over budget, the renderer cuts from the end (markdown first, then
messages, warnings, and failures, last rows first), truncates any single
text that alone exceeds the budget, and ends with "…and 312 more findings;
all of them are in the workflow run's summary". The full rendering always
goes to `$GITHUB_STEP_SUMMARY`, which holds 1 MiB per step.

### When there's nothing to report

| Option | Existing summary | No summary yet |
|---|---|---|
| **A. All clear** | updated to "No findings on `<sha>`", with the footer | nothing posted |
| B. Delete (danger-js's default) | deleted | nothing posted |
| C. Always post | updated | "No findings" posted on every clean pull request |

**Recommendation (A).** Reviewers who saw the failures find the
resolution where they saw them, and GitHub's edit history keeps the old
findings; a deleted comment just vanishes, which reads like a glitch. A
clean pull request never gets a comment, so A adds no noise. Open
question 5 asks for the choice.

### Stale runs

A run for an older commit can finish after a run for a newer one and
overwrite its summary. The Action's documentation sets a `concurrency`
group per pull request with `cancel-in-progress: true`, and just before
writing, the runner re-reads the pull request (`pulls/get`, one request)
and skips posting when its head is no longer `headCommit`: a newer run
will post. The skip is logged, not an error.
