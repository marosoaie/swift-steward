# swift-steward — contributor & agent guide

Conventions for working in this repository. Written for humans and coding
agents alike; nothing here is specific to any particular tool or model.

## What this is

A Swift package that surfaces build/lint diagnostics only on lines a pull
request touches, and Steward, a pure-Swift Danger. Five products on top of
the `GitDiffKit` library, strict dependency direction:

| Product | Depends on | Purpose |
|---|---|---|
| `GitDiffKit` (dependency) | – | Unified git diffs → changed files + line ranges, from [git-diff-parser](https://github.com/marosoaie/git-diff-parser) |
| `BuildLogKit` | – | Build/lint logs → `[Diagnostic]` (xcodebuild, SwiftLint, SwiftFormat, SonarQube parsers) |
| `DiffDiagnostics` | both above | The join: which diagnostics land on changed lines |
| `steward` (CLI, target `StewardCLI`) | all three | `changes` and `filter` subcommands |
| `Steward` | `GitDiffKit`, `BuildLogKit`, `DiffDiagnostics`, `PullRequestHosting`, `GitHubAPI` | A Dangerfile's DSL, context, runner, and built-in diagnostics rule |
| `StewardTesting` | `Steward` | Fixture contexts and a fake host for a Dangerfile's tests |

`GitDiffKit` and `BuildLogKit` must never import each other; only
`DiffDiagnostics` couples them. `StreamParsing` is an internal target
(chunk-to-line splitting, shared via the `package` access level) — never
expose it as a product. `StewardVersion` is another: the release version,
one constant that `steward --version` and `Steward`'s reports both read.
Libraries take no third-party dependencies;
swift-argument-parser is allowed in the CLI target only, and Apple's
swift-openapi-runtime and swift-openapi-urlsession in the `GitHubAPI`
target only.

`PullRequestHosting` (not a product) is the host seam: the
`PullRequestHost` protocol and its models, with no dependencies.
`GitHubAPI` (not a product) implements it as `GitHubHost`, over a
GitHub REST client generated from GitHub's OpenAPI description and
committed under `Generated/`. Generated types stay internal, so they
never reach public API: map them to hand-written models instead. Never
edit the generated code: change `Specs/github/` and regenerate. The generator
lives in the nested `Tooling/` package, which the root manifest never
depends on. See [docs/github-api.md](docs/github-api.md) for the pin, the
spec fixes, and how to update them.

`Steward` is the pure-Swift Danger replacement that
[docs/danger.md](docs/danger.md) designs, on top of `GitDiffKit`,
`PullRequestHosting`, `GitHubAPI`, `BuildLogKit` and `DiffDiagnostics`.
It has the DSL (`Rule`, `Finding`, the `Dangerfile` protocol), the
`Context` it builds from the GitHub Actions variables, the event payload
and the local checkout, the runner, and the built-in rule
`Rule.diagnosticsOnChangedLines(in:failingOn:)`, which maps a build's
diagnostics to the head and keeps the ones on changed lines, as
`steward filter` does. In CI the runner writes the report and the job
summary and posts the summary as one sticky comment, and anywhere else
it's a dry run that prints the summary. It runs git with every
output-shaping option pinned, so a user's configuration can't change what
it parses. It re-exports `GitDiffKit` and `PullRequestHosting`, so a
Dangerfile imports only `Steward`; generated types stay out of its public
API. `StewardTesting` is for a Dangerfile's tests
([docs/rule-tests.md](docs/rule-tests.md)): `Context.fixture(diff:)`
parses a diff with the parser a run uses, `FakePullRequestHost` records
what a run posts, and `Dangerfile.run(on:postingTo:)` runs every rule
after the context exactly as `main()` does, through the `package` hook
`FixtureRun`. It re-exports `Steward`. `FixtureContextOracleTests` and
`FakeHostOracleTests` hold both to real runs: keep them passing when
either side changes. `DangerfileFixture`, under `Tests/`, is a test-only
executable target: a Dangerfile the end-to-end tests run as a process,
whose rules `StewardTestingTests` test as a user's tests would, and which
depends on `Steward` alone, as a user's would.

`GitDiffKit` comes from the first-party git-diff-parser package, pinned to
tagged versions (`from:`) only, never a branch or revision: SwiftPM rejects
those underneath a versioned package. For lockstep changes, use
`swift package edit git-diff-parser` locally, then tag the library and bump
the requirement. The root package must not be *named* `git-diff-parser`,
nor checked out into a directory of that name (a root package's identity
is its directory name): either way SwiftPM takes the root as an override
of the dependency and fails to resolve.

## Commands

```sh
swift build                        # must complete with zero warnings
swift test                        # full suite (~20 s warm); also on Linux
GIT_DIFF_PARSER_SKIP_NETWORK_TESTS=1 swift test   # offline subset
xcodebuild test -scheme swift-steward-Package -destination platform=macOS
swift build -c release            # for benchmarks — never benchmark debug builds
swiftlint lint --quiet            # must print nothing
Tooling/generate-github-api.sh    # regenerate the GitHub client from Specs/github
swift test --package-path Tooling # the spec-fix engine and the fix list
```

SwiftLint's configuration (`.swiftlint.yml`, with a `Tests/.swiftlint.yml`
override) encodes the mechanically checkable parts of the style below —
functional-preference rules are opted in, force unwraps are allowed in tests
only. Keep the whole tree violation-free; PR CI additionally annotates and
fails on violations on PR-touched lines. When a rule fights a deliberate
design decision, disable it in config or inline — always with a comment
saying why.

Real-world test fixtures resolve from
`~/Library/Caches/git-diff-parser-tests/` (on Linux,
`$XDG_CACHE_HOME/git-diff-parser-tests/` or `~/.cache/…`), then the network.
PR CI runs the build and the full suite on macOS and, in a `swift:6.2`
container, on Linux; locally, `docker run -v "$PWD":/src swift:6.2` does the
same (copy the tree out of `/src` first so the two `.build` folders don't mix).

## Coding style

**Functional over imperative.** Prefer `map` / `filter` / `compactMap` /
`reduce` / `flatMap` / `contains(where:)` / `forEach` over `for` and `while`
loops wherever practical. An imperative loop is the exception and needs to
earn its place: a measured hot path (byte-level scanning, binary search), a
stateful cursor that combinators would obscure, or a mid-scan feedback
condition that isn't a clean fold. When you keep one, say why in a comment.
When output size is unbounded, stream through `forEach` or `.lazy` rather
than materializing intermediate arrays.

**Value types only.** Structs and enums; no classes. Caseless enums as
namespaces. Composition over inheritance: tool-specific behavior is injected
as `@Sendable` closures (see `ClangStyleLogParser`'s `refine` hook), not
subclassed.

**Swift API Design Guidelines** for all public API: argument labels that
read as prose (`contains(line:in:tolerance:)`), initializers for conversions
(`ChangedLines(diff:)`), `consume(...)`/`finalize()` for streaming builders.
Every public symbol carries a doc comment that starts with a one-sentence
summary; document behavioral quirks (normalization, performance caveats) at
the declaration. Public model types get explicit public memberwise
initializers. JSON key names are wire contracts — decouple them from Swift
property names with `CodingKeys` instead of renaming properties.

**Strict concurrency and memory safety.** The package enables
`ExistentialAny`, `MemberImportVisibility`, `InferIsolatedConformances`,
`NonisolatedNonsendingByDefault`, and `strictMemorySafety()` on every
target. Keep the build warning-free — a warning is a defect. Mark value
types `Sendable`; a type that can't be (e.g. it stores a `Regex`) stays
deliberately non-Sendable rather than lying.

**Never trap on untrusted input.** Diffs and logs are hostile input:
overflow-check arithmetic at parse boundaries
(`multipliedReportingOverflow`), never subscript a `split` result without
`omittingEmptySubsequences: false`, order comparisons so extreme values
can't overflow, no force unwraps outside tests. Libraries do not throw on
malformed input — they degrade locally (skip the damaged file, keep
parsing). Only the CLI throws (`ValidationError`, `ExitCode`) and only the
test support throws `FixtureError` (with a remediation hint).

**Streaming invariants.** Hot paths parse bytes (`ArraySlice<UInt8>`);
`String` and `Regex` are only reached after a cheap byte-level gate. Results
must be byte-for-byte identical for any input chunking (tested down to
1-byte chunks). Wrap `FileHandle.read` loops in an autoreleasepool on Darwin
(`withAutoreleasePool`, or `#if canImport(Darwin)`; Linux has none) — without
it the autoreleased chunks accumulate and streaming silently degrades to
whole-file memory. Store line sets as merged ranges (`LineRangeSet`), never
per-line collections.

**Multiline string literals over `+`-concatenated literals** — for any
multi-part string (fixtures, messages, help text), use `"""` with `\`
line-continuations and interpolation. Significant trailing whitespace inside
a literal is spelled `\u{20}` so editors and linters can't eat it.

**Doc comments on public API; elsewhere only where names fall short.**
Public symbols always get the doc comment described above. Non-public
declarations (methods, types, properties, and the like) get a doc comment
only when their names and, for methods, parameter labels don't make the
behavior clear. Beyond the required public summary, keep every comment to
the point and explain why, not what — constraints, traps, and
justifications (e.g. why a loop stays imperative, why a pool per read
iteration), never narration of the next line.

## Testing

- swift-testing (`@Suite`/`@Test`) with sentence-style names
  ("a diff truncated mid-hunk neither invents lines nor loses the next
  file"); parameterized tests via `arguments:`; traits for `.serialized`,
  `.timeLimit`, `.enabled(if:)`.
- Validate against **oracles**, not hand-computed expectations, where one
  exists: the CLI's per-file changed-line counts are cross-checked against
  `git apply --numstat` on real diffs (Linux kernel, redis,
  swift-argument-parser). The diff parser's own edge-case tests live in
  the library.
- Every bug fix lands with a regression test (see `MalformedInputTests`).
- The CLI's output on real inputs is pinned by fingerprint
  (`CommandLineOutputTests`), so macOS and Linux must print the same bytes.
  When a change alters output on purpose, pin the new fingerprints the test
  reports, and say so in the PR.
- Performance-relevant changes are benchmarked on the kernel-diff fixtures
  in release mode before merging; parsing throughput (~0.2 s / 70 MB) and
  flat peak memory are the budget.
- Tests must pass under both `swift test` and Xcode/`xcodebuild test` — the
  runners lay out build products differently (see `CommandLineTool.url`).

## Git

- Commit subjects in imperative mood; bodies explain the why and any
  verification performed.
- Never commit large binaries, and no Git LFS: brew and SwiftPM consumers
  clone this repo, and LFS breaks checkouts on machines with missing or
  misconfigured `git-lfs`. Big test fixtures are downloaded and cached at
  test time instead.
- Material from another project (a fixture, a spec) is committed with its
  licence next to it and an entry in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Releases: bump `Release.version` (in `Sources/StewardVersion`) via PR,
  then run the "Release" workflow (Actions tab) with the matching semver
  number and branch. It tests, packages the arm64 binary, tags `vX.Y.Z`,
  publishes a GitHub release with generated notes, and pins the Homebrew
  formula in marosoaie/homebrew-tap to the new tag (via the
  `TAP_DEPLOY_KEY` secret).
  The maintainer drives version numbers — never change the version outside
  this procedure.
