# swift-steward

**Steward** checks your pull requests with rules written in Swift, and
posts what they find as one comment on the pull request. It's a pure-Swift
[Danger](https://danger.systems):

- **No Node, no danger-js.** The rules are a SwiftPM package beside your
  own, and its executable is the whole runner: it reads the pull request,
  runs the rules, and posts the comment.
- **Runs on Linux runners**, and on macOS: in GitHub Actions, a checkout
  and one Action on `ubuntu-latest`.
- **Typed, testable rules.** A rule is a value, a name and a closure from
  the pull request's context to its findings, so a test calls it on a
  context built from a diff and checks what it returns, with `swift test`.

A built-in rule reports the build and lint diagnostics that land on the
lines a pull request changes:

```swift
import Steward

@main
struct Checks: Dangerfile {
    static var rules: [Rule] {
        Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log"), .swiftLint("swiftlint.log")])

        Rule("Changelog") { context in
            guard !context.git.modifiedFiles.contains("CHANGELOG.md") else { return [] }
            return [.warning("Add a CHANGELOG entry.")]
        }
    }
}
```

No release has Steward yet: until one does, a Dangerfile depends on this
repository's `main` branch, and Steward's API may still change.

## Where to start

- [Quickstart](docs/quickstart.md): add the template `Dangerfile/` package
  to your repository, write rules, and run them on pull requests.
- [Testing a Dangerfile's rules](docs/rule-tests.md) with `StewardTesting`.
- [steward-action](https://github.com/marosoaie/steward-action), the
  GitHub Action that runs a Dangerfile.
- [Migrating from danger-swift](docs/migrating-from-danger-swift.md).
- [The design](docs/danger.md), with the decisions and their alternatives.

## The `steward` command

`steward` shows only the build/lint diagnostics that a pull request actually
touches, outside a Dangerfile. Two subcommands, matching the two halves of
the problem:

1. **`changes`** — parse a unified git diff and list every file + line number
   the PR **added or modified** (deleted lines are ignored: they can't carry
   warnings).
2. **`filter`** — parse a build/lint log, intersect it with those changed
   lines, and emit only the diagnostics that land on them — ready to post as
   PR annotations or comments.

Inputs are streamed, so kernel-sized diffs and gigabyte logs are fine — a
70 MB diff parses in ~0.2 s with flat memory (see
[implementation notes](INTERNALS.md)).

### Installation

Via [Homebrew](https://github.com/marosoaie/homebrew-tap):

```sh
brew tap marosoaie/tap
brew trust marosoaie/tap   # one-time; Homebrew 6 gates third-party taps
brew install marosoaie/tap/steward
```

Up to v1.0.2 the tool was called `git-diff-parser`. `brew upgrade` moves an
existing `git-diff-parser` install over to `steward`; scripts and workflows
that call the old name need updating.

Prebuilt arm64 binaries ship with each
[release](https://github.com/marosoaie/swift-steward/releases), with SHA-256
checksums attached. They are not yet notarized, so fetch them with `curl`/`gh
release download` (browser downloads get quarantined by Gatekeeper).

Or build from source (Swift 6.2+, on macOS 26+ or Linux):

```sh
swift build -c release
# binary at .build/release/steward
```

### `changes` — what lines does the PR touch?

```sh
git diff origin/main...HEAD | steward changes -
steward changes pr.diff --format text
```

Output (`json` default, or `text` as greppable `path:line` lines). Changed
lines are reported as closed ranges — contiguous runs stay compact no matter
how large the edit:

```json
[
  {
    "lineCount" : 3,
    "path" : "Sources/App/Greeter.swift",
    "ranges" : [
      {
        "end" : 3,
        "start" : 3
      },
      {
        "end" : 6,
        "start" : 5
      }
    ]
  }
]
```

Line numbers are **new-side** (post-PR) numbers — the same ones your build log
and GitHub's PR view use. Modified lines count as added (git represents a
modification as remove + add). Deleted and binary files never appear; renames
appear under their new path, and only if they contain edits.

### `filter` — which diagnostics should the PR show?

```sh
steward filter build.log --diff pr.diff --format github
```

The log is scanned for the de-facto standard clang format that `swiftc`,
`xcodebuild`, SwiftLint, and SwiftFormat all emit — everything else in the
log is ignored, so pipe the raw build output straight in. Colours are fine:
terminal escape codes are removed before matching, and Swift 6.4's
`swift build` colours its diagnostics even when piped.

```
/path/to/File.swift:42:13: warning: variable 'x' was never used
```

| Option | Meaning |
|---|---|
| `--tool <tool>` | Log dialect: `generic` (default, any clang-style log), `xcodebuild`, `swiftlint`, `swiftformat`, or `sonar` (a SonarQube `/api/issues/search` JSON report). Tool-specific parsers also extract the violated rule — SwiftLint rule identifier, SwiftFormat rule name, clang warning flag, Sonar rule key — into the `rule` field (and the GitHub annotation title) |
| `--format json` | Structured output for your own PR-comment bot (default) |
| `--format github` | `::warning file=…,line=…::…` workflow commands — GitHub renders these as PR annotations automatically |
| `--format text` | clang-style lines, for humans |
| `--repo-root <path>` | Strip this prefix from absolute log paths. Usually unnecessary: unmatched absolute paths fall back to longest component-aligned suffix matching |
| `--tolerance <n>` | Also keep diagnostics within *n* lines of a change. `0` (default) is right for compiler warnings; `1`–`2` helps with lints that anchor on a declaration a line or two above the edit |
| `--fail-on <severity>` | Exit 1 if anything at/above `note`/`warning`/`error` matched — lets CI blocking be scoped to *new* problems only |

Duplicate diagnostics (same file/line/message, common in multi-target
`xcodebuild` runs) are collapsed. See `steward help <subcommand>` for
the full reference.

### Getting the right diff

Use the **three-dot** diff against the merge base so you only see the PR's own
changes, not what happened on main since branching:

```sh
git fetch origin main
git diff origin/main...HEAD > pr.diff
```

On GitHub you can also download the PR's diff directly
(`https://github.com/OWNER/REPO/pull/N.diff`, or
`gh pr diff N > pr.diff`) — same format, parses identically.

### CI recipes

**GitHub Actions — zero-infrastructure annotations.** Emit workflow commands;
GitHub attaches them to the PR's changed lines in the Files tab:

```yaml
- run: git fetch origin ${{ github.base_ref }}
- run: |
    set -o pipefail
    xcodebuild build ... 2>&1 | tee build.log
- run: |
    git diff origin/${{ github.base_ref }}...HEAD \
      | .build/release/steward filter build.log --diff - \
          --format github --fail-on error
```

This repository dogfoods exactly that recipe: every PR runs
[.github/workflows/pr.yml](.github/workflows/pr.yml), which executes the test
suite, runs SwiftLint, and filters both logs against the PR diff — new
warnings on changed lines annotate the PR and fail the job
(`--fail-on warning`).

**SonarQube.** The scanner doesn't print per-issue diagnostics, so after
your pipeline uploads the analysis, fetch the open issues back from the
server and filter them like any other input:

```sh
curl -sf -u "$SONAR_TOKEN:" \
  "$SONAR_HOST/api/issues/search?componentKeys=$PROJECT_KEY&pullRequest=$PR_NUMBER&resolved=false&ps=500" \
  > sonar.json
steward filter sonar.json --diff pr.diff --tool sonar --format github
```

(Drop `pullRequest=` when you only analyze branches.) Issue paths are
relative to `sonar.projectBaseDir`; the usual suffix matching resolves them
when that is the repo root. Past 500 issues the API pages (`&p=2`, …) —
merge pages with `jq -s '[.[].issues[]]' page*.json`, a shape the parser
also accepts.

**Steward, or your own bot.** In a Dangerfile, Steward's
`Rule.diagnosticsOnChangedLines` does this filtering itself (see the
[quickstart](docs/quickstart.md#2-write-the-rules)). For another bot, use
`--format json` and post each entry as an inline comment via your API of
choice; `file` is repo-relative and `line` is the new-side line number,
which is exactly what the GitHub review-comment API (`side: RIGHT`)
expects.

## Using the libraries

The package exports four library products and builds on a fifth, so other
tooling — e.g. a Danger-Swift plugin — can depend on exactly the layer it
needs:

| Product | What it does |
|---|---|
| `GitDiffKit` | Unified git diffs → changed files and line ranges (`DiffParser`, `ChangedLines`). From the [git-diff-parser](https://github.com/marosoaie/git-diff-parser) library |
| `BuildLogKit` | Build/lint logs → diagnostics. `ClangStyleLogParser` handles any clang-style log; `XcodeLogParser`, `SwiftLintLogParser`, and `SwiftFormatLogParser` additionally extract the violated rule. All conform to `LogParsing` |
| `DiffDiagnostics` | The join: `DiagnosticMatcher` filters diagnostics to the lines a diff touches (depends on both of the above) |
| `Steward` | A pure-Swift Danger: a `Dangerfile` package's rules, and a built-in one for build and lint diagnostics on changed lines, check a pull request in GitHub Actions and post one summary comment ([quickstart](docs/quickstart.md), [design](docs/danger.md)). Re-exports `GitDiffKit` |
| `StewardTesting` | For a Dangerfile's tests: `Context.fixture(diff:)` builds the context a run would, and `Dangerfile.run(on:)` runs every rule against a fake host ([how to write a rule test](docs/rule-tests.md)) |

```swift
// Package.swift
.package(url: "https://github.com/marosoaie/git-diff-parser.git", from: "0.2.0"),
.package(url: "https://github.com/marosoaie/swift-steward.git", branch: "main"),
// target dependencies (pick what you need):
.product(name: "GitDiffKit", package: "git-diff-parser"),
.product(name: "BuildLogKit", package: "swift-steward"),
.product(name: "DiffDiagnostics", package: "swift-steward"),
```

All model types are `Sendable` and the package builds with Swift 6.2 strict
concurrency.

```swift
import BuildLogKit
import DiffDiagnostics
import GitDiffKit

// Whole-string convenience — or stream chunks into a DiffParser for
// inputs that shouldn't be held in memory:
var parser = DiffParser()
while let chunk = nextChunk() { parser.consume(chunk) }   // [UInt8], ArraySlice<UInt8>, or String
let changes = parser.finalize()                           // == ChangedLines(diff: wholeText)

changes.contains(line: 42, in: "Sources/App/Foo.swift")   // binary search
let kept = DiagnosticMatcher.match(
    SwiftLintLogParser.diagnostics(in: lintLog),          // rule-aware
    against: changes
)
```

## Matching semantics (the fine print)

- Log paths are usually absolute (`/Users/ci/checkout/Sources/App/Foo.swift`)
  while diff paths are repo-relative (`Sources/App/Foo.swift`). The matcher
  tries an exact match, then `--repo-root` stripping, then falls back to the
  longest suffix match aligned on `/` boundaries — so `FooBar.swift` never
  matches `Bar.swift`, and an ambiguous basename resolves to the most specific
  changed path.
- Duplicate diagnostics are collapsed on their complete value — same
  location but a different message or violated rule stays distinct.
- Inputs stream in constant memory, with two caveats: single lines are
  processed truncated to 1 MiB, and `filter`'s memory scales with the number
  of diagnostics in the log (not the log's size).
- `remark:` (clang) is treated as `note`; clang's `fatal error:` is an
  `error`.

## Project documentation

- [INTERNALS.md](INTERNALS.md) — implementation details: streaming design,
  benchmarks, and how the parser is validated against real-world diffs.
- [AGENTS.md](AGENTS.md) — contribution conventions and coding style, written
  for humans and coding agents alike. Read it before contributing.
- [docs/github-api.md](docs/github-api.md) — the GitHub client Steward posts
  with, generated from GitHub's OpenAPI description, and how to update it.

Steward's user docs are under [Where to start](#where-to-start).

## License

[MIT](LICENSE). GitHub's REST API description, the client generated from
it, and two test fixtures come from other projects and keep their own
licences: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
