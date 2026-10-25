# The GitHub API client

The `GitHubAPI` target is a GitHub REST client that
[swift-openapi-generator](https://github.com/apple/swift-openapi-generator)
generates from GitHub's published OpenAPI description. It's filtered to
the operations Steward calls, and the output is committed. Nothing here is
public API: 3.5's host seam wraps the client, so generated types never
reach Steward's users.

| Path | What it holds |
|---|---|
| `Specs/github/upstream.env` | The pin: a commit of `github/rest-api-description` and the file's SHA-256 |
| `Specs/github/openapi-generator-config.yaml` | The operations kept, and the generator's options |
| `Specs/github/fixes.yaml` | The reviewed fixes to the description, one per entry |
| `Specs/github/openapi.yaml` | The generator's input: the filtered, fixed description. Written by the pipeline, committed for review |
| `Sources/GitHubAPI/Generated/` | The generated client. Written by the pipeline; never edit it by hand |
| `Tooling/` | A nested package with the generator and the spec-fix engine, so the root manifest never depends on them |
| `Tests/GitHubAPITests/` | Recorded responses and event payloads, the tests that decode them, and the opt-in live test |

## Regenerating

```sh
Tooling/generate-github-api.sh
```

The script downloads the pinned description (13 MB, cached in
`Tooling/.build/spec-cache/`) and stops if its SHA-256 differs from the
pin. Then it runs `swift-openapi-generator filter`, applies `fixes.yaml`
with `github-spec-fix`, and generates the client. It writes
`Specs/github/openapi.yaml` and `Generated/` only when every step
succeeds. From a cold cache it builds the generator in release mode
first, which takes a few minutes; after that a run takes about 40 s.

To see exactly what the fixes change, compare the filtered description
with the committed input:

```sh
diff Tooling/.build/spec-cache/filtered.yaml Specs/github/openapi.yaml
```

The generator is pinned `exact:` in `Tooling/Package.swift`, because its
output is committed: a new generator version is a reviewed change, like a
new pin.

## Updating the pin

`github/rest-api-description` has cut no release since v2.1.0
(2022-10-25); its descriptions change on `main` through automated
commits. So the pin is a commit plus the checksum of one file.

1. Pick a commit and compute the file's checksum:
   ```sh
   curl -sSfL "https://raw.githubusercontent.com/github/rest-api-description/<commit>/descriptions/api.github.com/api.github.com.2022-11-28.json" | shasum -a 256
   ```
2. Set `SPEC_COMMIT`, `SPEC_COMMIT_DATE`, and `SPEC_SHA256` in
   `upstream.env`, and run the script.
3. If it fails naming a fix, upstream has changed what the fix edits:
   - "drop the fix": upstream now says what the fix said. Delete the
     entry and its test, in `SpecFixRegressionTests` or, for an
     adaptation, `SpecAdaptationTests`. Keep a correction's fixture: the
     response still has to decode, so move its test to
     `FixtureDecodingTests`.
   - "update the fix": the node the fix edits is gone or has moved. Find
     where it went in the new description and change the entry.

   One run reports every fix that no longer applies, not just the first.
4. Review `git diff Specs/github/openapi.yaml`: it shows what upstream
   changed in the operations Steward uses. Then run the tests.

The pinned file is API version 2022-11-28: it's what GitHub serves when a
request names no version, and it's the version GitHub Enterprise Server
supports.

## Adding a fix

Every fix that corrects upstream ships with the recorded response that
decodes wrongly without it, the same regression-test rule as for parser
fixes.

1. Record the response as `Tests/GitHubAPITests/Fixtures/<operation>.<scenario>.http`:
   `HTTP <status>`, the kept headers (see `RecordedResponse`), a blank
   line, then the body. The live test's recorder writes this format for
   the responses it reads (see [The live test](#the-live-test)). Scan it
   for tokens before committing.
2. Add an entry to `fixes.yaml` with a `name`, a `why`, the `fixture`, and
   the `edit`.
3. Add a test to `SpecFixRegressionTests`, named `"<fix name>: …"`, that
   replays the fixture and asserts what the fix declares.
4. Regenerate, and run both test suites. The Tooling tests check that the
   fixture exists and that a regression test names the fix and replays
   the fixture.

Before committing, drop the entry, regenerate, and watch the new test
fail: a test that passes either way proves nothing. (The two 404 tests
stop compiling instead, since their operation loses its `notFound`
case.) The Tooling tests
can't run that check themselves, because it takes a regeneration per
fix.

The kinds of edit are `makeNullable`, `makeOptional`, `addEnumValue`,
`undeprecate`, `remove`, and `addResponse`
(`Tooling/Sources/GitHubSpecFixes/SpecFix+Edit.swift`). A new kind needs
a case there, its transform in `SpecFix+Application.swift`, and a test.

Two kinds don't correct upstream and need no fixture: `remove` (the fix
list uses it to drop the 20,000-line `x-webhooks` extension, which the
generator never reads) and `undeprecate` (the generated initializers
assign deprecated properties, which warns, and the build must be
warning-free). Such an adaptation still gets a test, named
`"<fix name>: …"`, in
`Tooling/Tests/GitHubSpecFixesTests/SpecAdaptationTests.swift`: it checks
the committed `openapi.yaml` for the fix's effect, so it fails once the
entry is dropped and the client regenerated (a removed node is back, a
deprecation marker returns).

The Tooling tests fail when a fix has no test named after it, and when a
test is named after a fix that's no longer on the list, so a dropped fix
can't leave a test that passes for no reason.

### Why a Swift transform, and why the list is YAML

Decision 4 (2026-10-25) chose a small Swift transform over JSON Patch and
OpenAPI Overlays. It needs no toolchain besides Swift, it addresses its
targets by intent (a schema and a property, not an array index), it keeps
the document's key order, so `diff` shows only what the fixes change, and
every edit refuses to apply once upstream makes it redundant. The 3.2
spike's write-up (`docs/github-api-spike.md` in
[swift-steward#21](https://github.com/marosoaie/swift-steward/pull/21))
has the comparison.

The engine is Swift, in `Tooling/`; the list itself is data in
`Specs/github/fixes.yaml`, decoded into `[SpecFix]`. That keeps the pin
and the fixes, which change together when the pin moves, in one folder;
dropping or adding a fix doesn't touch Swift code; and the YAML comments
and `why` fields read as the review record. What Swift values would add,
compile-time checking of the entries, the decoder and `SpecFixList`'s
rules cover at the start of every run: an unknown kind of edit, a missing
field, a duplicate name, or a correction without a fixture all fail.

## Tests

| Suite | Checks |
|---|---|
| `FixtureDecodingTests` | Every recorded response for the five operations decodes through the client's real path: status dispatch, content-type check, JSON decoding. Fails when a file in `Fixtures/` isn't replayed by any test |
| `EventPayloadTests` | The `GITHUB_EVENT_PATH` payloads of an `opened` and a `synchronize` event decode with the REST `PullRequest` and `Repository` schemas, which `pulls/get` uses too |
| `SpecFixRegressionTests` | One test per correction, on its fixture |
| `SpecAdaptationTests` (Tooling) | One test per adaptation, on the committed `openapi.yaml` |
| `RepositoryFixListTests` (Tooling) | Every fix has a test named after it and no test outlives its fix; every fixture a fix names exists; every fix detects its own result |
| `LiveClientSupportTests` | The live test's client, offline: it refuses writes, sends the token without ever printing it, and records fixtures byte for byte |
| `LiveTests` | Opt-in: real responses from api.github.com decode |

The offline suites run on macOS and Linux in PR CI. The Tooling suites run
in the drift guard's job.

Not covered by fixtures: pull requests from forks and paginated comments,
since this repository has neither, and recording another project's pull
request text and comments into this one isn't ours to do. The live test
covers both.

### The live test

```sh
STEWARD_LIVE_GITHUB_TESTS=1 GITHUB_TOKEN=$(gh auth token) swift test --filter LiveTests
```

It's skipped unless `STEWARD_LIVE_GITHUB_TESTS` is `1`, and CI doesn't set
it. It catches what fixtures can't: GitHub changing a response after the
pin. It sends eight requests to api.github.com, all `GET`, about a second
in all:

- `pulls/get` on [swift-steward#20](https://github.com/marosoaie/swift-steward/pull/20)
  (same repository, merged) and on
  [apple/swift-openapi-generator#883](https://github.com/apple/swift-openapi-generator/pull/883)
  (from a fork, merged);
- `issues/list-comments` on the latter, two pages of five comments as
  `full+json`, linked by the `link` header;
- a missing pull request and issue (the declared 404), a bad token (the
  undeclared 401), and the diff media type (still undeclared).

The environment:

| Variable | Effect |
|---|---|
| `STEWARD_LIVE_GITHUB_TESTS=1` | Runs the live test |
| `GITHUB_TOKEN` | Optional, since the pull requests are public. Authenticates the requests, raising the rate limit from 60 an hour to 5,000 |
| `STEWARD_LIVE_GITHUB_RECORD_DIR` | Records every response there as `<operation>.live-<scenario>.http`, keeping only `RecordedResponse`'s headers |

It never creates or changes anything on GitHub: every client it builds
refuses any method but `GET` before the request leaves the process
(`ReadOnlyMiddleware`, with an offline test). So `issues/create-comment`,
`update-comment`, and `delete-comment` aren't exercised live here; 3.5
checks the write path on a sandbox pull request.

When it fails, GitHub changed something. Run it again with
`STEWARD_LIVE_GITHUB_RECORD_DIR` set and compare the recording with
`Specs/github/openapi.yaml`. If the description is wrong, the recording
becomes the fixture for a new fix (rename its scenario after who recorded
it, `macos-…` or `actions-…`; see [Adding a fix](#adding-a-fix)).

## The drift guard

`.github/workflows/github-api.yml` runs on PRs that touch the spec, the
client, its tests, or `Tooling/`. It runs the Tooling tests, regenerates
from the pinned spec, and fails if `Specs/github/` or `Generated/` differ
from what's committed, including new files the generator added. So a hand
edit to the generated code fails it, and so does a change to the pin, the
fixes, or the generator version without regenerating.

It runs on Linux (`swift:6.2`): a cheaper runner, and the same image as
the `linux-tests` job. Both platforms produce the same bytes. On
2026-10-25, the pipeline run from a cold spec cache in `swift:6.2` (Swift
6.2) and on macOS 26 (Swift 6.4) wrote identical `openapi.yaml` and
`Generated/`, and repeated runs on each were identical too.

That needs `SWIFT_DETERMINISTIC_HASHING=1`, which the script sets.
`filter` decodes vendor extensions (`x-github`) and examples into
dictionaries and writes their keys in hash order, and Swift seeds its
hashing randomly per process: without the variable, every run reordered
about 450 lines of `openapi.yaml`, on either platform. The generated Swift
didn't change. If a future toolchain hashes differently on one platform,
the guard fails on a regeneration that is otherwise clean; then sort the
keys inside those free-form values in `github-spec-fix` instead.

## Coverage

The swift-steward ruleset's `code_coverage` rule (minimum 70%, at most a
1-point drop) reads line coverage only from Cobertura reports that a
workflow uploads with `actions/upload-code-coverage`, which needs GitHub
Code Quality enabled on the repository. As of 2026-10-25 no workflow
uploads one and Code Quality is off, so the rule passes with no data.

When an upload is added, leave `Sources/GitHubAPI/Generated/` out of the
report, for example with
`llvm-cov export -ignore-filename-regex='Sources/GitHubAPI/Generated/'`
when converting to Cobertura. The fixture tests exercise the operations
Steward calls, but most of the generated code is Codable conformances and
initializers for schema members nothing reads. Measured on 2026-10-25
with `swift test --enable-code-coverage` (in-process line coverage, so
the `steward` CLI, which the tests run as a subprocess, isn't counted):

| | Lines | Covered |
|---|---|---|
| Hand-written sources | 388 | 97.7% |
| `Generated/` | 2,435 | 55.9% |
| Both | 2,823 | 61.6%, under the 70% minimum |

The `.gitattributes` entry that marks `Generated/` as generated doesn't
exclude it from coverage; it only collapses it in PR diffs.
