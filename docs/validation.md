# Validation record

What was run to check Steward, the Dangerfile runner, in real
repositories and on real runners, as of 2026-10-29 (plan step 5.0,
Track B). Every pull request listed here ran Steward through
[steward-action](https://github.com/marosoaie/steward-action), and every
comment and annotation it left was checked by hand against the log it came
from: right file, right line of the head commit, nothing missed on a
changed line, nothing reported off one. GitDiffKit's own validation, the
diff parser underneath, is in
[git-diff-parser's record](https://github.com/marosoaie/git-diff-parser/blob/main/docs/validation.md).

Steward ran in two outside repositories, the playground and a fork of
NetNewsWire, on 23 pull requests between them; Track C of the same step
adds a third, a fork of a project that uses danger-swift. The
maintainer's private app, and a pull request from a second account's
fork, were skipped.

## At a glance

| Where | What ran | Pull requests | Result |
|---|---|---|---|
| [steward-playground](#steward-playground) | A Python package, ruff converted to a SonarQube report, on 5 kinds of runner | 7, 14 runs | Every finding on its line; none off changed lines |
| [Clean installs](#clean-installs) | Homebrew, the release binary, a source build on Linux | – | All print `2.0.0` |
| [The maintainer's private app](#the-maintainers-private-app) | Xcode and SwiftLint logs | 1, no run of Steward | Skipped: its macOS job never got a runner |
| [NetNewsWire](#netnewswire) | A Mac and iOS app, 16 changes merged upstream replayed: two `xcodebuild` logs and SwiftLint | 16, 38 runs | 406 findings, each on its line; none off changed lines |
| [A fork's pull request](#a-pull-request-from-a-fork) | – | – | Skipped: playground PR 6 shows a read-only token |

## How each run was checked

For every run: the tool's own output in the job log (ruff's issues, the
build's and SwiftLint's diagnostics) against the pull request's diff,
which gives the findings that belong on changed lines; then Steward's
summary comment, its job summary, and the annotations GitHub kept, read
back through the check run's annotations
(`GET /repos/{owner}/{repo}/check-runs/{id}/annotations`), each line
against the head commit's file. GitHub shows job summaries only to
signed-in viewers, so they were read from the log: Steward writes the same
text to the log's Summary group as to `GITHUB_STEP_SUMMARY`, and warns when
that write fails or doesn't fit, which no run did. Once checked, each
pull request was closed and its branch deleted; its comment, annotations
and runs stay, and the links here still work.

Versions: Steward 2.0.0 from swift-steward `main` at `d2224d2` (each
Dangerfile's `Package.resolved`), steward-action at `325c70a`, with
`actions/checkout@v7`. Local checks: macOS 26.6.2, git 2.54.0, SwiftLint
0.65.1.

## steward-playground

[marosoaie/steward-playground](https://github.com/marosoaie/steward-playground),
public, made for this: a small Python package checked by the quickstart's
template Dangerfile (description, changelog, conflict markers) plus
`Rule.diagnosticsOnChangedLines(in: [.sonar("ruff-sonar.json")])`. Steward
reads SonarQube's `GET /api/issues/search` response, so a composite action
runs ruff 0.11.13 and converts its JSON with one `jq` filter: the path
becomes the component (`playground:src/…`), syntax errors and undefined
names are `CRITICAL` (failures), the rest `MAJOR` (warnings). One job per
pull request, its runner picked by the head branch's prefix, so no two
jobs post over each other's summary.

| PR | Runner (Swift) | Scenario | Findings on changed lines | Comment, annotations | Result |
|---|---|---|---|---|---|
| [1](https://github.com/marosoaie/steward-playground/pull/1) | ubuntu-24.04 (6.4.1) | 3 ruff warnings, then a push that fixes them | `frequencies.py` 4, 12, 14 | 3 and 3, on those lines; after the fix the same comment says **No findings**, 0 annotations | ✓ |
| [2](https://github.com/marosoaie/steward-playground/pull/2) | ubuntu-22.04 (6.4) | Opened as a draft with no description, then marked ready, then described; no changelog entry | `counting.py` 16, 17; description; changelog | Draft: 3 warnings, no description finding. Ready: plus the description failure, job fails. Described: back to 3 warnings, job passes. Annotations on 16 and 17 only (the others have no location) | ✓ |
| [3](https://github.com/marosoaie/steward-playground/pull/3) | ubuntu-24.04-arm (6.4.1) | An undefined name, then a fix | `cli.py` 18 (critical) | 1 failure, an error annotation on 18, job fails; after the fix **No findings** | ✓ |
| [4](https://github.com/marosoaie/steward-playground/pull/4) | macos-26 arm64 (6.3.3) | 12 unused imports, then an edited description | `sentences.py` 3–14 | All 12 in the comment; GitHub kept 10 annotations (3–12), its limit per type per step; the edit reran with the same result | ✓ |
| [5](https://github.com/marosoaie/steward-playground/pull/5) | `swift:6.2` container (6.2.4) | Two problems on one line | `test_counting.py` 15, twice | 2 warnings, 2 annotations on 15 | ✓ |
| [6](https://github.com/marosoaie/steward-playground/pull/6) | ubuntu-24.04, read-only token | The workflow's default token | `stopwords.py` 3, 11 | No comment; Steward warns that it couldn't post and says to grant `pull-requests: write`; both annotations; job passes | ✓ |
| [7](https://github.com/marosoaie/steward-playground/pull/7) | ubuntu-24.04 | Conflict markers committed in the README | `README.md` 23, 27 | 2 failures, 2 error annotations, job fails | ✓ |

In every run ruff's one finding on an unchanged line
(`counting.py:3`) stayed out. Jobs took 62–127 s when the Action built the
Dangerfile from scratch, 50–70 s from its cache; GitHub scopes caches to
a pull request, so every pull request's first run is a cold build, as the
Action's README says.

Two failures along the way were the playground's own: the swift:6.2
image has no `curl`, so ruff never installed in PR 5's first runs, and
Steward rightly failed on the missing report ("Couldn't read the SonarQube
report `ruff-sonar.json`"); and reopening the pull request reran the old
test merge, so the fix reached it only after a rebase.

## Clean installs

`install.yml` in the playground, on fresh runners, each ending in
`steward --version`:

| How | Runner | Result |
|---|---|---|
| `brew tap marosoaie/tap`, `brew trust`, `brew install marosoaie/tap/steward` | macos-26 arm64, Homebrew 7.0.9 | Formula 2.0.0 built from source in 39 s; prints `2.0.0` |
| The latest release's `steward-2.0.0-macos-arm64.zip`, checked with its `.sha256` | macos-26 arm64 | Checksum OK; prints `2.0.0` |
| `git clone` swift-steward, `swift build -c release` | `swift:6.2` (6.2.4, x86_64) | `main` at `d2224d2` builds; prints `2.0.0` |

## The maintainer's private app

Skipped, because its one job that runs Steward never got a runner.

The trial pull request swapped the workflow's `steward filter` step for
steward-action and a Dangerfile with one rule,
`Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log"), .swiftLint("swiftlint.log")], failingOn: .warning)`,
which checks what `filter --fail-on warning` did (its 5 tests passed
locally). The rule runs in the workflow's `macos-26` job, the first run
the workflow ever had, and that job never started:

| Attempt | Queued (UTC) | Outcome |
|---|---|---|
| 1 | 14:31 | Cancelled by GitHub at 14:46: "The job was not acquired by Runner of type hosted even after multiple attempts" |
| 2 | 14:47 | The same at 15:02 |
| 3 | 15:03 | The same at 15:18 |

During the first attempt, four `macos-26` jobs in the public playground
got a runner within 5 s each. The run's timing API reports 0 billable
milliseconds for every job. The cause wasn't looked into: the
maintainer chose to skip the job. So the one commit planned as a replay
(a SwiftLint `line_length` warning on a changed test line) wasn't pushed
either, since only that job would have checked it.

## NetNewsWire

[marosoaie/NetNewsWire](https://github.com/marosoaie/NetNewsWire), the
maintainer's public fork of the NetNewsWire feed reader: a Mac and iOS
app built from an Xcode project and local Swift packages, with SwiftLint
and warnings as errors. Sixteen changes merged upstream were replayed
unchanged as pull requests. Each base branch is the merge's first
parent plus one commit that adds Steward's workflow and Dangerfile, and
each head is the merged change on top, so a pull request's diff is
exactly what upstream merged and its test merge has the head's tree.
Every pull request's one job, on `macos-26`, builds the Mac app and the
iOS app for the simulator with `xcodebuild`, runs SwiftLint, and runs
Steward through the Action with one rule,
`Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build-macos.log"), .xcodebuild("build-ios.log"), .swiftLint("swiftlint.log")])`:
errors fail (the default), warnings warn.

At those commits the project needs three things to build unsigned on a
runner, all of which it changed later, so the workflow does them in the
working tree only and the diff Steward reads is untouched. Its resources
come from synchronized folders, and Xcode knows a `.nnwtheme` folder as
a bundle only where NetNewsWire is installed, so on a runner it copies
the themes' files flat and they collide ("Multiple commands produce"):
their files go. Two script phases re-sign with the build's identity,
which an unsigned build hasn't got: their `codesign` calls become
no-ops. And the Debug flags warn on code that takes over 300 ms to
type-check, which warnings as errors turns into a failed build on a busy
runner: those two flags go. Finding them took four runs of PR 1 and a
second round of PRs 6–16; the table has each pull request's last run.
All 38 runs on the fork were Steward's: upstream's CI workflow isn't in
these old bases.

Versions: runner image macos-26-arm64 20261013.0424.1 and
20261021.0445.8 (8 jobs each), macOS 26.6.2, Xcode 26.6 with the macOS
and iOS Simulator 26.5 SDKs, SwiftLint 0.65.1 from Homebrew, and Swift
6.3.3 building the Dangerfile.

Checked as for the playground, with a script: each log's diagnostics,
deduplicated as BuildLogKit does, on the lines the head adds over the
base, using git's rename detection as Steward does; against the comment's
rows and the annotations, as (severity, path, line) multisets; then
every finding's line in the head commit, each of the 309 whitespace
findings by its text, the 94 of other rules by the construct the rule
names (a comma's spacing, `String(decoding:as:)`, an `override`), and
the 3 compiler findings by reading them.

| PR | Change | Files, lines | Log diagnostics (Mac, iOS, SwiftLint) | On changed lines | Comment, annotations | Result |
|---|---|---|---|---|---|---|
| [1](https://github.com/marosoaie/NetNewsWire/pull/1) | Import OPML files into FreshRSS accounts | 2, +25 −1 | 3, 5, 10 | The same compiler warning from each build; `trailing_whitespace`, `vertical_whitespace` | 4 and 4 | ✓, see [B5](#b5-one-diagnostic-from-two-logs) |
| [2](https://github.com/marosoaie/NetNewsWire/pull/2) | Share from the Mac timeline's context menu through a sharing service picker | 2, +25 −30 | 2, 4, 36 | 5: `trailing_whitespace` 4, `trailing_newline` 1 | 5 and 5 | ✓ |
| [3](https://github.com/marosoaie/NetNewsWire/pull/3) | Remember the iOS split view's display mode across launches | 4, +41 −17 | 2, 4, 17 | 10: `trailing_whitespace` 9, `vertical_whitespace` 1 | 10 and 10 | ✓ |
| [4](https://github.com/marosoaie/NetNewsWire/pull/4) | Fix widget truncation and alignment | 12, +168 −91 | 2, 4, 22 | 11: `trailing_whitespace` 10, `trailing_newline` 1 | 11; GitHub kept 10 annotations | ✓ |
| [5](https://github.com/marosoaie/NetNewsWire/pull/5) | Fix truncation in the iOS timeline's feed cells | 4, +109 −71 | 2, 4, 19 | 10: `trailing_whitespace` 9, `vertical_whitespace` 1 | 10 and 10 | ✓ |
| [6](https://github.com/marosoaie/NetNewsWire/pull/6) | Fix layout issues in the iOS timeline's cells | 5, +142 −123 | 2, 4, 45 | 37 `trailing_whitespace` | 37; 10 | ✓ |
| [7](https://github.com/marosoaie/NetNewsWire/pull/7) | Merge the iOS timeline's cell types into one | 7, +677 −685 | 2, 8, 57 | 48: `trailing_whitespace` 44, `vertical_whitespace` 2, `unneeded_override` 1, `trailing_newline` 1 | 48; 10; the iOS build fails | ✓, see below |
| [8](https://github.com/marosoaie/NetNewsWire/pull/8) | Rebuild the iOS timeline on a collection view | 7 (1 renamed), +1218 −843 | 2, 4, 125 | 117: `trailing_whitespace` 101, `vertical_whitespace` 9, 7 of five other rules | 117; 10 | ✓, see below |
| [9](https://github.com/marosoaie/NetNewsWire/pull/9) | Use hierarchical text colours in the iOS timeline's cells | 2, +213 −155 | 2, 4, 171 | 46: `trailing_whitespace` 42, `statement_position` 2, `unneeded_override` 1, `trailing_newline` 1 | 46; 10 | ✓ |
| [10](https://github.com/marosoaie/NetNewsWire/pull/10) | Fix light and dark backgrounds in the iOS timeline and settings | 8 (1 renamed), +421 −331 | 2, 4, 38 | 31: `trailing_whitespace` 25, `vertical_whitespace` 3, `comma`, `unused_optional_binding` and `trailing_newline` 1 each | 31; 10 | ✓ |
| [11](https://github.com/marosoaie/NetNewsWire/pull/11) | Simplify the iOS timeline's cells and fix their context menu previews | 6, +157 −359 | 2, 4, 7 | None | No comment, no annotations | ✓ |
| [12](https://github.com/marosoaie/NetNewsWire/pull/12) | Tweak the iOS cell previews and remove unused code | 5, +40 −33 | 2, 4, 8 | 1 `trailing_whitespace` | 1 and 1 | ✓ |
| [13](https://github.com/marosoaie/NetNewsWire/pull/13) | Manage notifications per account on iOS | 4, +195 | 2, 5, 108 | 1 error from the iOS build | 1 failure, an error annotation, job fails | ✓, see below |
| [14](https://github.com/marosoaie/NetNewsWire/pull/14) | Show paths for browsers with the same name in Mac settings | 2, +65 −4 | 2, 4, 110 | None | No comment, no annotations | ✓ |
| [15](https://github.com/marosoaie/NetNewsWire/pull/15) | Fix the full-screen article view on iOS | 2, +1 −9 | 2, 4, 20 | None | No comment, no annotations | ✓ |
| [16](https://github.com/marosoaie/NetNewsWire/pull/16) | Replace the XML parser with one written in Swift | 155 (14 renamed), +9186 −7033 | 2, 4, 103 | 85: `comma` 46, `optional_data_string_conversion` 36, `trailing_newline` 2, `implicit_optional_initialization` 1 | 85; 10 | ✓ |

No run reported anything off a changed line or dropped a line the head
doesn't have. Each pull request with findings has one comment, which
later runs edited in place; the three without findings got none ("nothing
to post"). Every finding was also an annotation, and GitHub kept the
first 10 per step. The annotations API returns GitHub's own too, on the
path `.github`: a failed step's exit code, and on every job here a notice
that macOS arm64 jobs may queue longer.

Three pull requests are worth a closer look:

- **PR 8**: SwiftLint warns about a second blank line in
  `MainTimelineModernViewController.swift` on a line the change didn't
  touch. Git sees the file as a 67% rename of
  `MainTimelineViewController.swift`, and the blank lines came with it,
  so Steward, which diffs with rename detection as the Files tab shows
  the file, left the warning out. A check without rename detection
  expects it; the quickstart now says what a renamed file's changed lines
  are.
- **PR 7**: the change as merged upstream doesn't build for iOS. It
  removes two cell types that four unchanged lines elsewhere in the
  timeline still name, and the build fails on four "cannot find type"
  errors. None is on a changed line, so Steward reports none of them, and
  its comment says "48 warnings" while the job fails on the build step:
  see [B4](#b4-a-broken-build-whose-errors-arent-on-changed-lines).
- **PR 13**: Xcode 26.6 can't type-check an expression on an added line
  (`AccountNotificationInspectorView.swift:51`) in reasonable time, a
  real error with this compiler. Steward reports it as a failure with an
  error annotation and fails the job.

## A pull request from a fork

Skipped, by the maintainer's choice. GitHub runs a fork's pull request
with a read-only token, and playground PR 6 already shows how Steward
behaves with one: it warns that it couldn't post the comment, naming the
permission to grant, and the annotations and the job summary still carry
the findings.

## Findings

Fixed:

- The quickstart told users to turn colours off, saying Steward can't
  read them. That stopped being true with
  [#34](https://github.com/marosoaie/swift-steward/pull/34), so its build
  step now keeps them (this record's pull request). steward-action's
  README said the same, and is fixed by
  [steward-action#3](https://github.com/marosoaie/steward-action/pull/3)
  (`e012627`).
- The quickstart didn't say which lines of a renamed file count as
  changed (NetNewsWire PR 8), or that errors without a location, or on a
  line the pull request broke without changing it (PR 7), show only as
  the build step's failure. It does now.
- One diagnostic that two logs gave alike was reported twice (NetNewsWire
  PR 1, [B5](#b5-one-diagnostic-from-two-logs)), and
  [#40](https://github.com/marosoaie/swift-steward/pull/40) reports it
  once.

Intended, and documented:

- GitHub keeps 10 annotations per type per step (PR 4), and the summary
  comment keeps every finding.
- A tool's message is escaped in the summary, so nothing in a log can
  change how the comment renders; ruff's code spans show their backticks
  there.
- With a read-only token Steward can't post. It warns, naming the
  permission to grant, and the annotations and the job summary still
  carry the findings (PR 6).

Not Steward's:

- On the Ubuntu runners (Swift 6.4), `swift run` prints "warning:
  safeExec: signal(32, SIG_DFL) failed: Invalid argument", and the same
  for 33, before Steward starts. Swift 6.2.4 in the container and macOS
  print neither. Harmless.
- Reopening a pull request reruns its old test merge commit, even after
  the base has moved; a push or a rebase makes a new one (PR 5).
- GitHub shows job summaries only to signed-in viewers.
- The tap's formula has no bottle, so `brew install` builds from source
  (39 s on macos-26).
- NetNewsWire at the replayed commits needs three working-tree changes
  to build unsigned on a runner, and one replayed change doesn't build
  for iOS (PR 7).
- The check run's annotations include GitHub's own, on the path
  `.github`.

Open for step 5.1: [B2](#b2-annotations-without-a-column),
[B3](#b3-report-formats-other-than-sonarqubes-api) and
[B4](#b4-a-broken-build-whose-errors-arent-on-changed-lines).

## Questions

### B2: annotations without a column

`Location` has a path and an optional line, so Steward's annotations
carry no `col=`, although most sources know one: clang-style logs give
`file:line:column`, and SonarQube's `textRange` a `startOffset`. Two
findings on one line (PR 5) differ only by their text. A column is a new
`Location` property, public API, so it waits for step 5.1.

### B3: report formats other than SonarQube's API

`.sonar` reads what a SonarQube server's `GET /api/issues/search`
returns. Linters that write a report themselves use other shapes, SARIF
(ruff, SwiftLint) or Sonar's Generic Issue Import format, and Steward
reads neither, so the playground converts ruff's JSON with an eight-line
`jq` filter. A SARIF source would need no converter. A new source is
public API, so it waits for step 5.1.

### B4: a broken build whose errors aren't on changed lines

The build sources read diagnostics written as `file:line: severity:`,
and the rule keeps the ones on changed lines. A build can fail with none
there: on errors without a location, such as Xcode's "Multiple commands
produce …", a linker's undefined symbol, or a package that won't
resolve; or on lines the pull request broke without changing them.
Steward's summary then lists what it did find and says nothing of the
failure. NetNewsWire PR 1's first run reported "2 warnings", SwiftLint's,
while both of its builds had failed with "0 diagnostics" in each log;
PR 7's comment says "48 warnings" while its iOS build fails on four
errors on unchanged lines. Only the failed build steps show the
breakage, and the quickstart now says so. Steward could also say, in the
summary, that a log holds errors it didn't report, which changes what
the built-in rule reports, so it's a question for step 5.1.

### B5: one diagnostic from two logs

BuildLogKit drops a log's repeated diagnostics, but nothing merges one
diagnostic that two sources report. In NetNewsWire PR 1 both builds
compile the shared Account package and warn about the same unused value
on the same line, so the comment lists it twice and it has two
annotations. Fixed by
[#40](https://github.com/marosoaie/swift-steward/pull/40), as the
maintainer decided: the rule leaves out a diagnostic that matches one an
earlier report gave in every part (path, line, column, severity, message
and rule), and logs how many it left out. A report's own repeats stay,
as `steward filter` keeps them. It changes the rule's output, not its
API.
