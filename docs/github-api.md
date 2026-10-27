# The GitHub API client

The `GitHubAPI` target is a GitHub REST client that
[swift-openapi-generator](https://github.com/apple/swift-openapi-generator)
generates from GitHub's published OpenAPI description. It's filtered to
the operations Steward calls, and the output is committed. The generated
types are internal: `GitHubHost`, the GitHub implementation of the host
seam, wraps the client, so they never reach Steward's users (see
[The host seam](#the-host-seam)).

| Path | What it holds |
|---|---|
| `Specs/github/upstream.env` | The pin: a commit of `github/rest-api-description` and the file's SHA-256 |
| `Specs/github/openapi-generator-config.yaml` | The operations kept, and the generator's options |
| `Specs/github/fixes.yaml` | The reviewed fixes to the description, one per entry |
| `Specs/github/openapi.yaml` | The generator's input: the filtered, fixed description. Written by the pipeline, committed for review |
| `Specs/github/LICENSE` | GitHub's licence for the description (MIT), upstream's `LICENSE.md` at the pinned commit. Written by the pipeline; every generated file's header points to it |
| `Sources/GitHubAPI/Generated/` | The generated client. Written by the pipeline; never edit it by hand |
| `Sources/GitHubAPI/*.swift` | `GitHubHost` and its helpers, written by hand |
| `Sources/PullRequestHosting/` | The host seam: the `PullRequestHost` protocol and its models, with no dependencies |
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
`Specs/github/openapi.yaml`, `Specs/github/LICENSE` (downloaded from the
pinned commit too), and `Generated/` only when every step succeeds. From
a cold cache it builds the generator in release mode first, which takes
a few minutes; after that a run takes about 40 s.

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
   changed in the operations Steward uses. A change to
   `Specs/github/LICENSE` means upstream changed its licence: check that
   it still allows committing the description and the client, and update
   [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Then run the
   tests.

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

## The host seam

Steward talks to GitHub only through `PullRequestHost`, a protocol in the
dependency-free `PullRequestHosting` target: read a pull request; find,
create, update, and delete the summary comment. Its models
(`PullRequest`, `SummaryComment`, `PullRequestHostError`) are
hand-written, so regenerating the client never changes public API, and a
rule's tests can fake a host without the OpenAPI runtime. `GitHubHost`
implements it for one repository:

```swift
let host = GitHubHost(
    owner: "marosoaie",
    repository: "swift-steward",
    token: environment["GITHUB_TOKEN"],
    apiURL: apiURL,                       // GITHUB_API_URL in Actions
    summaryAuthor: "github-actions[bot]"  // optional
)
```

The choices, made in step 3.5:

- **Which comment is the summary.** The one whose first line is exactly
  `<!-- steward-summary -->`, an HTML comment GitHub renders as nothing.
  The host adds the line when it posts and strips it from what it
  returns, so callers see only their own text. A CRLF after the marker
  counts (GitHub's web editor writes CRLF); a reply that quotes the
  summary, or a marker anywhere but the first line, doesn't. With
  `summaryAuthor` set, only that login's comments count (ignoring case, as
  GitHub compares logins), so nobody else's comment can be overwritten by
  putting the marker on its first line.
  `summaryComments(onPullRequest:)` returns every match, oldest first,
  because two runs that race can each create one; 4.4 decides which one
  to keep. The marker is fixed for now; 4.1's design doc decides the
  summary's format, and whether several Dangerfiles need markers of
  their own.
- **Pagination.** Comments are listed 100 a page (GitHub's maximum), and
  the next page is read only while the `link` header names a
  `rel="next"`. An empty page ends the list whatever the header says.
  After 100 pages (10,000 comments) the host gives up with a
  `malformedResponse` error rather than read forever or quietly miss a
  summary, which would make 4.4 post a second one.
- **Errors.** Every failure is a `PullRequestHostError`, whether the
  description declares the status or not. Its `kind` is what a caller
  acts on, and `status` and `message` (GitHub's `message`, such as "Bad
  credentials") are for the log. Cancellation stays a `CancellationError`,
  even when URLSession reports it as `URLError(.cancelled)`.

  | GitHub answers | `kind` |
  |---|---|
  | 401 (declared nowhere) | `unauthorized` |
  | 403 with `x-ratelimit-remaining: 0`, a `retry-after`, or "rate limit" in the message; or 429 | `rateLimited` |
  | any other 403 | `forbidden` |
  | 404, or 410 (issues turned off) | `notFound` |
  | 422 | `rejected` |
  | 5xx, with or without a `retry-after` | `serverError` |
  | any other status, such as 304 or 406 | `unexpectedStatus` |
  | no response | `network` |
  | a success that doesn't decode, such as the diff media type | `malformedResponse` |

  `RateLimitMiddleware` reads the rate-limit headers, and a server
  error's `retry-after`, on every response, because the generated client
  drops headers for declared statuses (such as `issues/create-comment`'s
  403). An error status whose body isn't
  GitHub's JSON still maps by status.
  Updating a comment someone deleted fails as `notFound` (thanks to the
  `update-comment-404` fix), so 4.4 can post a new one. Deleting a
  comment that's already gone succeeds (the `delete-comment-404` fix),
  and returns false, so the caller can tell it didn't delete it.
  Nothing is retried here: whether a rate limit is worth waiting for is
  the runner's call. A `rateLimited` error, or a `serverError` whose
  response has a `retry-after`, carries the wait GitHub asked for as
  `retryAfter`: the `retry-after` seconds, or, once the primary limit is
  spent, the time left until `x-ratelimit-reset`. Steward's
  sticky comment retries once (docs/danger.md, section 6).
- **The token** lives in a `Credential` that prints as `<redacted>` in
  descriptions, debug output, and `dump`. It's added by a middleware, so
  the request a `ClientError` prints never carries it, and an empty token
  is treated as none.
- **Event payloads.** `PullRequest`'s mapping from the REST schema also
  maps an Actions event's `pull_request`, which decodes with the same
  schema, so 4.2 can read the context from `GITHUB_EVENT_PATH` without an
  API call.

GitHub caps a comment at 65,536 characters and answers a longer one with
a 422 (`rejected`). `GitHubHost.maximumSummarySize` is what's left of
65,536 UTF-8 bytes once the marker line is added, and Steward cuts its
summary to it (docs/danger.md, section 5). Left for later: `head.repo` is
null for a pull request from a deleted fork, which the schema doesn't
allow, so it fails as `malformedResponse`. v1 posts on same-repository
pull requests only, so that can't happen yet.

## Tests

| Suite | Checks |
|---|---|
| `FixtureDecodingTests` | Every recorded response for the five operations decodes through the client's real path: status dispatch, content-type check, JSON decoding. Fails when a file in `Fixtures/` isn't replayed by any test |
| `EventPayloadTests` | The `GITHUB_EVENT_PATH` payloads of an `opened` and a `synchronize` event decode with the REST `PullRequest` and `Repository` schemas, which `pulls/get` uses too |
| `SpecFixRegressionTests` | One test per correction, on its fixture |
| `SpecAdaptationTests` (Tooling) | One test per adaptation, on the committed `openapi.yaml` |
| `RepositoryFixListTests` (Tooling) | Every fix has a test named after it and no test outlives its fix; every fixture a fix names exists; every fix detects its own result |
| `GitHubHostPullRequestTests` | `GitHubHost` maps every recorded pull request, and `PullRequestEvent` both event payloads, compared with the JSON read by `JSONSerialization`; JSON that isn't a `pull_request` payload throws; the request it sends |
| `GitHubHostCommentTests` | The spike's recorded create → list → update → delete exchange, replayed request by request; the marker and author rules; pagination over made-up pages; deleted comments; the size budget, marker included |
| `GitHubHostErrorTests` | Every status, recorded or made up, maps to its `kind`; the wait a throttled response asks for; network failures and cancellation; the token never shows up in descriptions, `dump`, or errors |
| `SummaryMarkerTests`, `LinkHeaderTests` | The first-line rule, CRLF included; `rel="next"` parsing |
| `LiveClientSupportTests` | The live test's client, offline: it refuses writes, sends the token without ever printing it, and records fixtures byte for byte |
| `LiveSandboxSupportTests` | The write test's fence, offline: it lets through the sandbox pull request's requests and nothing else |
| `LiveTests`, `LiveHostTests` | Opt-in: real responses from api.github.com decode, and `GitHubHost` maps them as the raw responses say |
| `LiveSandboxTests` | Opt-in, writes: the summary comment's whole life on a sandbox pull request |

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

`LiveHostTests` runs with the same variable and sends nine more `GET`s
through `GitHubHost`. It maps both pull requests and compares each with
the raw response it came from. It also finds the fork pull request's
last comment by its first line at five comments a page, which takes two
pages, and compares the result with one page of 100.

Neither suite creates or changes anything on GitHub: every client they
build refuses any method but `GET` before the request leaves the process
(`ReadOnlyMiddleware`, with an offline test).

### The live write test

```sh
STEWARD_LIVE_GITHUB_WRITE_TESTS=1 STEWARD_SANDBOX_REPOSITORY=<owner>/<name> \
    STEWARD_SANDBOX_PULL_REQUEST=<number> GITHUB_TOKEN=<token> \
    swift test --filter LiveSandboxTests
```

The one test that writes, for Phase 3's "the client creates, updates, and
deletes a comment on a sandbox PR". It's skipped unless
`STEWARD_LIVE_GITHUB_WRITE_TESTS` is `1`, and it fails before sending
anything if the other three variables are missing. The token needs to
be able to comment on the pull request. Its comment carries a marker
unique to the run, and `SandboxOnlyMiddleware` refuses every request
except reads in the sandbox repository, comments on its pull request,
and edits of issue comments there, before the request leaves the
process. So the test can't touch another repository, another pull
request, or a comment it didn't find through its own marker.

It reads the pull request, creates the comment, finds it (two comments a
page, so it pages through any others), updates it, finds it again, and
deletes it. After each step it checks the raw comment list, read without
the host. Then it checks GitHub's two 404s for the deleted comment:
deleting it again succeeds, and updating it fails as `notFound`. If a
step fails after the comment exists, it deletes the comment before
failing. At least 13 requests in all, more when the pull request has
other comments.

Steward's `LiveStickyCommentTests` (in `StewardTests`) takes the same
variables, and `STEWARD_SANDBOX_SUMMARY_AUTHOR`, the token's login, so
only its comments count, as in a run:

```sh
STEWARD_LIVE_GITHUB_WRITE_TESTS=1 STEWARD_SANDBOX_REPOSITORY=<owner>/<name> \
    STEWARD_SANDBOX_PULL_REQUEST=<number> STEWARD_SANDBOX_SUMMARY_AUTHOR=<login> \
    GITHUB_TOKEN=<token> swift test --filter LiveStickyCommentTests
```

It runs the sticky comment through the runs a pull request sees: a clean
run posts nothing, the first run creates the comment, the next updates
it, a planted duplicate is collapsed into the oldest, an oversize summary
is cut to fit and accepted, a run for another commit writes nothing, and
a clean run turns it all clear. After each step it checks the raw comment
list. Its fence, `OwnCommentsMiddleware`, is tighter than
`SandboxOnlyMiddleware`: it lets through only reads of the pull request
and its comments, comments on it, and edits or deletes of comments
created through it. It deletes its comments at the end, or when a step
fails.

When either fails, GitHub changed something. Run it again with
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
