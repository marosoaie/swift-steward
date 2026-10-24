# GitHub API client spike (step 3.2)

Status: spike, 2026-10-24. The code on this branch is throwaway and won't
be merged. Step 3.3 (the spec pipeline) and the coordinator build on the
findings below.

The question was whether a client generated with swift-openapi-generator
from GitHub's published description covers the five operations Steward v1
needs, what upstream gets wrong, and how to express the fixes (open
decision 4).

## Answers

| Question | Answer |
|---|---|
| Pinned upstream | Commit `bb754941722779d8a5b3a2f25a5fbb7ce794e1ea` of `github/rest-api-description` (2026-10-17), file `descriptions/api.github.com/api.github.com.2022-11-28.json`, SHA-256 `309e30296b212d220ed143beeba216dbb0df11915daf79ee2ed01e06c6c9a586`. No release exists to pin to (see [Pin](#pin)). |
| Generator `filter` | The five operations plus three webhook payload schemas; see [Generator config](#generator-config). |
| Spec discrepancies | Three, none of them in a schema: an undeclared 404 on `issues/update-comment` and `issues/delete-comment`, an undeclared 401 on all five operations, and the undeclared `application/vnd.github.diff` media type on `pulls/get`. No nullability, `required`, or enum problems in any recorded response. See [Discrepancies](#discrepancies). |
| `GITHUB_EVENT_PATH` payload | Decodes. Real `opened` and `synchronize` payloads decode with the webhook schemas, and their `pull_request` decodes with the REST `pull-request` schema too. |
| URLSession transport on Linux | Works. The live tests (reads, a create → list → update → delete round trip, error cases) passed in a `swift:6.2` container in CI, as `github-actions[bot]`. Buffered only: the transport doesn't stream on Linux, which doesn't matter for these payloads. |
| Warning-free under the strict flags | Yes, after two adjustments: `accessModifier: internal` (with `package`, 18 unused-`package import` warnings), and removing three `deprecated` markers (3 deprecation warnings from the generated initializers). The macOS build has zero warnings; the Linux CI job builds with `-warnings-as-errors`. SwiftLint reports 1,647 violations in the generated code, so it's excluded. |
| Decision 4 | **A small Swift transform**, as built here. See [Decision 4](#decision-4-how-spec-fixes-are-expressed). |

## Pin

`github/rest-api-description` hasn't cut a release since v2.1.0
(2022-10-25); its tags stop there. The descriptions change on `main`
through automated "Update OpenAPI 3.0 Descriptions" commits, several a
week. So the pin is a commit plus the file's checksum, in
[`Specs/github/upstream.env`](../Specs/github/upstream.env):

```sh
SPEC_REPO=github/rest-api-description
SPEC_COMMIT=bb754941722779d8a5b3a2f25a5fbb7ce794e1ea   # 2026-10-17
SPEC_PATH=descriptions/api.github.com/api.github.com.2022-11-28.json
SPEC_SHA256=309e30296b212d220ed143beeba216dbb0df11915daf79ee2ed01e06c6c9a586
```

The file is 13,429,427 bytes of OpenAPI 3.0.3.
[`Tooling/generate-github-api.sh`](../Tooling/generate-github-api.sh)
downloads it from `raw.githubusercontent.com` at that commit, caches it
under `Tooling/.build/spec-cache/`, and stops if the checksum differs.

**API version 2022-11-28, not 2026-03-10.** The directory has both.
2022-11-28 is what GitHub serves when a request names no version, and
what GitHub Enterprise Server supports; `GITHUB_API_URL` makes GHES
reachable (4.2). The spike's middleware still sends
`X-GitHub-Api-Version: 2022-11-28`, so a change of default can't move us.
Moving to 2026-03-10 later would remove `merge_commit_sha` from pull
requests, and also `has_downloads` and `use_squash_pr_title_as_default`,
which are two of the three deprecation fixes below.

## Generator config

[`Specs/github/openapi-generator-config.yaml`](../Specs/github/openapi-generator-config.yaml):

```yaml
generate:
  - types
  - client
accessModifier: internal
namingStrategy: idiomatic
filter:
  operations:
    - issues/list-comments
    - issues/create-comment
    - issues/update-comment
    - issues/delete-comment
    - pulls/get
  schemas:
    - webhook-pull-request-opened
    - webhook-pull-request-synchronize
    - webhook-pull-request-reopened
```

Versions: swift-openapi-generator 1.14.2 (in the nested
[`Tooling/Package.swift`](../Tooling/Package.swift)),
swift-openapi-runtime 1.13.3, swift-openapi-urlsession 1.4.0,
swift-http-types 1.8.0. The root manifest carries only the runtime and
the transport, in the `GitHubAPI` target (decision 5).

The pipeline is download → verify → `swift-openapi-generator filter` →
`github-spec-fix` → `swift-openapi-generator generate`. With the tools
built, it takes about 35 s, most of it parsing the 13 MB description.
Two runs produced byte-identical output on macOS; the CI drift guard
(3.3) should regenerate on one platform, or 3.3 should check that Linux
produces the same bytes.

Facts about the output that 3.3 needs:

- **`filter` writes OpenAPI 3.1.0**, even though the input is 3.0.3
  (OpenAPIKit converts it). Nullability is `type: [boolean, 'null']`, not
  `nullable: true`, so fixes have to target the 3.1 form.
- **`filter` keeps root vendor extensions**: `x-webhooks` is 20,000 of the
  26,700 lines of the filtered document, and the generator never reads it.
  A fix removes it; the committed generator input,
  [`Specs/github/openapi.yaml`](../Specs/github/openapi.yaml), is 6,700
  lines.
- **The generator splits its output into nine files**: `Client.swift`
  and `Types+*.swift`, 12,207 lines in all, 9,635 of them in
  `Types+Components+Schemas.swift`. The webhook schemas account for most
  of it: without them the output is 5,272 lines. The `GitHubAPI` target
  takes about 13 s to compile in a debug build.
- **Access level.** `package` makes every generated file import
  `package import OpenAPIRuntime` and `Foundation` types, and in the
  files that declare nothing (`Types+Components.swift` and similar) the
  compiler warns that the import is unused: 18 warnings. With `internal`
  there are none, and tests reach the types through
  `@testable import GitHubAPI`. 3.5's wrapper lives in the same target,
  so `internal` costs nothing.

## Test setup

- **Fixture format** (`Tests/GitHubAPITests/Fixtures/<operation>.<scenario>.http`):
  `HTTP <status>`, the kept headers, a blank line, the body. Only
  `content-type`, `etag`, `link`, `x-github-media-type` and
  `x-github-api-version-selected` are kept, sorted, so request ids, OAuth
  scopes and token-expiry headers can't reach a fixture. The token is sent
  by a middleware and is never part of a response. Every recording was
  also scanned for `ghp_`/`ghs_`/`github_pat_` and `Authorization:`.
- **`FixtureTransport`** answers with a recorded response, so the offline
  tests decode through the generated client's real path: status
  dispatch, content-type check, JSON decoding.
- **`RecordingMiddleware`** writes each live response before the client
  decodes it, so a decoding failure still leaves its evidence.
- **Live tests** (`LiveTests`, opt-in through `STEWARD_SPIKE_*`
  environment variables) run on `URLSessionTransport`. Reads go to
  existing PRs; writes go only to this spike's draft PR (#21), and every
  comment created there was deleted again.
- **Field-by-field comparison**
  ([`Tooling/spike/compare-schema.py`](../Tooling/spike/compare-schema.py)):
  every recorded JSON body checked against the unfiltered description for
  undeclared keys, missing `required` keys, nulls in non-nullable
  properties, and values outside an enum. Decoding alone can't show all of
  these (see the caveat under [Discrepancies](#discrepancies)).

Recorded on 2026-10-24 by two identities: `macos-*` from the maintainer's
Mac with the keychain PAT (as `marosoaie`), `actions-*` from the CI job on
Linux with the job's `GITHUB_TOKEN` (as `github-actions[bot]`).

| Fixture | Shows |
|---|---|
| `pulls-get.macos-pr1` | A closed, unmerged PR decodes (`mergeable_state: blocked`) |
| `pulls-get.macos-pr20` | A merged PR decodes (`mergeable: null`, `rebaseable: null`, `merged_by` set) |
| `pulls-get.macos-pr21` | An open draft PR decodes |
| `pulls-get.macos-missing` | A missing PR decodes as the declared 404 |
| `pulls-get.macos-bad-token` | 401 Bad credentials: undeclared, `.undocumented(statusCode: 401, _)` |
| `pulls-get.macos-diff` | `application/vnd.github.diff`: undeclared, the client throws |
| `issues-list-comments.macos-pr20` | An empty page decodes |
| `issues-list-comments.macos-missing` | A missing issue decodes as the declared 404 |
| `issues-list-comments.macos-listed` | A page from `application/vnd.github.full+json` decodes, with `body_html` and `body_text` |
| `issues-list-comments.actions-listed` | A page with a bot's comment decodes |
| `issues-create-comment.macos-created` | 201 with the new comment decodes |
| `issues-create-comment.actions-created` | A comment by `github-actions[bot]` decodes, `performed_via_github_app` included |
| `issues-update-comment.macos-updated` | 200 with the edited comment decodes |
| `issues-update-comment.macos-update-deleted` | 404 for a deleted comment: undeclared (fixed below) |
| `issues-delete-comment.macos-deleted` | 204 decodes |
| `issues-delete-comment.macos-delete-deleted` | 404 for a deleted comment: undeclared (fixed below) |
| `pull-request-event.opened.json` | `GITHUB_EVENT_PATH` for `opened` decodes with both schemas |
| `pull-request-event.synchronize.json` | `GITHUB_EVENT_PATH` for `synchronize` decodes with both schemas |

## Discrepancies

Each discrepancy is listed with the fixture that shows it.

1. **Undeclared 404 on `issues/update-comment` and `issues/delete-comment`.**
   Both operations declare only their success responses (and 422 for
   update), but a comment that's gone answers
   `404 {"message":"Not Found", …}`
   (`issues-update-comment.macos-update-deleted`,
   `issues-delete-comment.macos-delete-deleted`). Without a fix, the
   client returns `.undocumented(statusCode: 404, _)`, which is a different
   case from any typed failure. Steward hits this when someone deletes the
   sticky comment by hand between runs. **Fixed** with two `addResponse`
   edits that point at the shared `not_found` response; the test
   "updating or deleting a deleted comment decodes the 404 the spec fixes
   declare" asserted `.undocumented(404)` before the fix (commit
   `01872a1`) and asserts `.notFound` after it.
2. **Undeclared 401 on all five operations.** A bad token answers
   `401 {"message":"Bad credentials", …, "status":"401"}`
   (`pulls-get.macos-bad-token`). **Not fixed**: the client returns
   `.undocumented(statusCode: 401, _)` without throwing, and 3.5's wrapper
   can map every undocumented status to one error. 403 and 429 (rate
   limits) are likewise declared only on `issues/create-comment` (403);
   they weren't recorded, because they can't be triggered safely.
3. **Undeclared media type on `pulls/get`.** With
   `Accept: application/vnd.github.diff`, GitHub answers
   `200` with `content-type: application/vnd.github.diff; charset=utf-8`
   (`pulls-get.macos-diff`); the description declares only
   `application/json`, so the client throws a `ClientError` whose cause
   names the unexpected content type. `application/vnd.github.patch`
   behaves the same (checked with curl, not recorded). **Not fixed**: v1 reads diffs from the local checkout.
4. **Not a discrepancy: `full+json` and the other `+json` variants** answer
   `content-type: application/json; charset=utf-8`; only
   `x-github-media-type` names the variant. They decode, and
   `body_html`/`body_text` are declared as optional properties.
5. **Not a discrepancy: GitHub App permissions.** The bot's comment carries
   18 keys in `performed_via_github_app.permissions` beyond the five the
   schema lists (`actions`, `pull_requests`, …). The schema declares
   `additionalProperties: {type: string}`, so they decode into
   `additionalProperties`.
6. **Not discrepancies: deprecations.** `repository.has_downloads`,
   `repository.use_squash_pr_title_as_default` and
   `repository-webhooks.use_squash_pr_title_as_default` are marked
   `deprecated`, so the generated memberwise initializers that assign them
   warn. Three `undeprecate` edits remove the markers; the client only
   decodes these schemas.

**No nullability, `required`, or enum discrepancies** turned up in any
recorded body: three pull requests (closed, merged, open draft),
comments by a user and by a bot, and both event payloads. The comparison
found no missing required key, no null in a non-nullable property, and no
value outside an enum.

Caveat: the generated decoders use `decodeIfPresent` for optional
properties, which turns a `null` into `nil`, so a null in an optional,
non-nullable property can never fail decoding; only required properties
can. The comparison script catches those cases; decoding doesn't.

Not covered, because this repo has none of them: PRs from forks
(`head.repo` can be null), comments by deleted users (`user` is the
`ghost` user or null), labels, milestones, auto-merge, requested teams,
more than one page of comments (`link` header), rate-limit responses, and
GHES.

## The event payload

`GITHUB_EVENT_PATH` from both default triggers that fired on #21
(`opened`, then `synchronize`):

- decodes with `Components.Schemas.WebhookPullRequestOpened` and
  `…Synchronize`;
- and its `pull_request` member decodes with the REST
  `Components.Schemas.PullRequest`, the type `pulls/get` returns;
- and the field-by-field comparison against both `webhook-pull-request-*`
  and `pull-request` finds no differences.

Decode it with `JSONDecoder` and `dateDecodingStrategy = .iso8601`, which
matches the runtime's default date transcoder.

**Recommendation for 4.2:** read the event's `pull_request` with the REST
`PullRequest` schema, and drop the three `webhook-pull-request-*` schemas
from the filter. One type then serves both the event and `pulls/get` (the
local dry run), and the generated code shrinks from 12,207 to 5,272 lines.
Fork PRs weren't tested (v1 targets same-repo PRs).

## Linux and the URLSession transport

- The `linux-live` job in
  [`.github/workflows/spike-github-api.yml`](../.github/workflows/spike-github-api.yml)
  runs `swift test --filter GitHubAPITests` in `swift:6.2` with the live
  environment set. Live reads, the round trip, the error cases and the
  offline fixture tests passed in every run on #21 (runs 40088648569,
  40088767679, 40089006075).
- The existing `linux-tests` job in `pr.yml` builds everything,
  `GitHubAPI` included, with `-warnings-as-errors`, and passed.
- `URLSessionTransport` is buffered on Linux: swift-openapi-urlsession
  supports streaming only on Darwin and points Linux users who need it to
  AsyncHTTPClient. Comment pages and pull requests are a few kilobytes, so
  buffering is fine.
- The middleware sends a `User-Agent` on both platforms, because GitHub
  rejects requests without one (an empty one gets 403, checked with curl).
  The spike didn't check what FoundationNetworking sends by default.
- **`pull-requests: write` is enough** for issue comments on a PR (the open
  question in 4.8): the workflow grants only `contents: read` and
  `pull-requests: write`, and create, update and delete all succeeded.
- **The posting identity** is `github-actions[bot]` (`type: Bot`,
  `author_association: NONE`, `performed_via_github_app.slug:
  github-actions`). 4.4's sticky-comment lookup can match on the marker
  plus that login.

## Decision 4: how spec fixes are expressed

The fixes this spike needed: two declared responses (`addResponse`),
three removed `deprecated` markers (`undeprecate`), and one removed root
key (`remove`). The typical future ones are making a property nullable,
dropping a property from `required`, and adding an enum value; all six
kinds are implemented and tested in
[`Tooling/Sources/github-spec-fix`](../Tooling/Sources/github-spec-fix).

| | JSON Patch (RFC 6902) | OpenAPI Overlay 1.0 | Swift transform (built here) |
|---|---|---|---|
| Tooling | None in the toolchain. Swift libraries round-trip through `JSONSerialization`, which loses key order; otherwise jq scripts, Node or Python | None in Swift, and the generator has no overlay support (checked in 1.14.2). Implementations are Node, Go or Python CLIs (Speakeasy, bump.sh, openapi-format) | An engine of about 140 lines plus the fix list, in the existing `Tooling` package. Yams already comes with the generator, so nothing new is added |
| Notices when upstream fixes it | Yes, with a `test` op before each change | No: a target that matches nothing is a silent no-op in most tools | Yes: every edit checks its precondition and fails, naming the fix to drop (tested) |
| Addressing | JSON Pointer: `/paths/~1repos~1{owner}~1{repo}~1issues~1comments~1{comment_id}/delete/responses/404`; array edits by index (`/required/3`), which breaks when upstream reorders | JSONPath, robust to order, but only `update` (merge) and `remove`; removing one value from `required` needs a filter expression that tools support unevenly | Intent: `.makeOptional(schema: component("pull-request"), property: "merged_by")`; array edits match by value |
| Evidence per fix | A free-text field next to the ops at best | `description` per action | `why` per fix, naming the fixture |
| Review | Data, but opaque paths | Data, readable targets | Swift values, read by Swift reviewers |
| Order of the output | Lost with `JSONSerialization` | Tool-dependent | Kept, so `diff` of the filtered and fixed documents shows only what the fixes change |

**Recommendation: the Swift transform.** It needs no new toolchain (an
Overlay CLI would put Node or Go back into a project whose pitch is "no
Node"), it refuses to apply a fix that upstream has made redundant, and
each fix names the discrepancy and fixture behind it. Costs: it's our own
format, a new kind of fix needs a new `Edit` case (about ten lines and a
test), and it only covers edits we've written.

For 3.3, keep the engine in `Tooling/` and consider moving the fix list
itself to `Specs/github/fixes.yaml` (decoded into `[SpecFix]`), which
matches the plan's layout ("one fix per entry, each with a comment saying
why") and keeps the data next to the pin. That changes where the list
lives, not the recommendation.

Bugs the transform's tests caught, worth keeping in mind: Yams compares
scalars by tag and quoting as well as text, so `'204'`, a plain `204` and
`Node("204")` are different keys to it. Lookups and precondition checks
have to compare `.string` values, or a check that upstream already
declares a 404 silently misses and appends a duplicate key.

## Notes for 3.3, 3.4 and 3.5

- Keep the pieces that worked: commit-plus-checksum pin, `filter` before
  fixing, generated input committed as `Specs/github/openapi.yaml`, the
  filtered document left in `Tooling/.build/` for `diff`, output in
  `Sources/GitHubAPI/Generated/` excluded from SwiftLint.
- The fixture format, `FixtureTransport` and `RecordingMiddleware` carry
  over to 3.4 as they are; `LiveTests` is the opt-in live test 3.4 asks
  for.
- The generated `Client` takes a `serverURL`, so `GITHUB_API_URL` plugs in
  directly; send `X-GitHub-Api-Version` and `User-Agent` from a middleware.
- Error bodies carry `status` as a string (`"404"`), matching the
  `basic-error` schema.
- 3.5's wrapper should treat a 404 from delete as "already gone", and map
  `.undocumented` responses (401, 403, 429) to one error with the status.
- Building the `Tooling` package from cold compiles OpenAPIKit, Yams and
  the generator; that's only for regeneration, never for users.

## Not settled by the spike

- Whether Linux regenerates byte-identical output (the drift guard's
  platform).
- Fork PRs, deleted users, paginated comments, rate limits, GHES, and the
  2026-03-10 API version.
