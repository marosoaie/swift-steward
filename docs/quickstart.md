# Steward quickstart

Steward checks a pull request with rules written in Swift, in a package
beside your own, and posts what they find as one comment on the pull
request; a finding with a location also shows on its line in Files
changed. There's no Node and no separate binary: the package's executable
is the runner. This page sets one up for GitHub Actions.
[danger.md](danger.md) is the design behind it.

You need Swift 6.2 or later, on macOS 26 or Linux, and GitHub Actions
`pull_request` workflows.

## 1. Add the Dangerfile package

From your repository's root, copy the template and check that it builds
and its tests pass:

```sh
curl -fsSL https://github.com/marosoaie/swift-steward/archive/refs/heads/main.tar.gz \
  | tar -xz --strip-components=2 swift-steward-main/Templates/Dangerfile
swift build --package-path Dangerfile
swift test --package-path Dangerfile
```

That gives you this layout:

```text
your-repository/
├── Package.swift                      your own package
├── Sources/
└── Dangerfile/
    ├── Package.swift                  depends on swift-steward
    ├── Package.resolved               written by the first build
    ├── Sources/Dangerfile/Checks.swift
    └── Tests/DangerfileTests/
```

`Dangerfile/` is an ordinary package: an executable target that depends on
the `Steward` library, and a test target that depends on `StewardTesting`.
It sits beside your package, not inside it, so it never joins your app's
build, and your app never builds Steward. Commit all of it, with the
`Package.resolved` the first build wrote: it pins the Steward revision
your rules run with. Its `.gitignore` keeps `.build` out.

**Steward's version.** No swift-steward release has Steward yet, so the
template depends on the `main` branch, at the revision `Package.resolved`
pins. `swift package update --package-path Dangerfile` moves the pin;
until the first release, Steward's API may still change between
revisions. Once a release has Steward, replace `branch: "main"` in
`Dangerfile/Package.swift` with `from:` and that version.

## 2. Write the rules

The rules are in `Dangerfile/Sources/Dangerfile/Checks.swift`. The
template has three examples; keep, change, or delete them:

| Rule | Finds | Reads |
|---|---|---|
| `description` | A failure when a pull request that's ready for review has no description | `context.pullRequest` |
| `changelog` | A warning when the pull request changes `Sources/` but not `CHANGELOG.md` | `context.git`'s file lists |
| `conflictMarkers` | A failure at each added line that starts a merge conflict's marker | `context.git.diff`, line by line |

A rule is a name and a closure from the context to findings: failures,
which fail the check, warnings, messages, and Markdown. A finding with a
`Location` links to that file and line in the pull request's head commit.
Each rule is a static property listed in `rules`, so its test can call it
by name: the template has a test for each rule, and one for the whole
Dangerfile. [Testing a Dangerfile's rules](rule-tests.md) says how to
write them.

**Diagnostics on changed lines.** `Rule.diagnosticsOnChangedLines(in:)`,
built in and commented out in the template, reports the build and lint
diagnostics that land on lines the pull request changes. It reads logs
that earlier steps of the same job wrote, with paths relative to the
repository's root, and a missing log is a failure. So first add the steps
that write the logs, before the one that runs Steward, and run Steward
even when they fail, so it reports a broken build's errors:

```yaml
- name: Build
  # Bash, for pipefail: without it a failed build passes the step, and a
  # container job's default shell, sh, has none. No colours, which Swift
  # 6.4 writes even into a file, and which Steward can't read.
  shell: bash
  run: swift build --no-color-diagnostics 2>&1 | tee build.log
- uses: marosoaie/steward-action@c606a4a637221b3d86c35e18c71aa4bbf6d9fecb
  if: ${{ !cancelled() }}
```

Without the Action, the step that runs `swift run --package-path
Dangerfile` takes the same `if:`.

Then uncomment the rule, with one source per log: `.xcodebuild` reads the
output of `xcodebuild`, `swift build`, or `swiftc`; `.swiftLint` the
output of `swiftlint lint`; `.swiftFormat` that of `swiftformat --lint`;
and `.sonar` a SonarQube issues report. A diagnostic at or above
`failingOn:` (errors, by default) is a failure; below it, a warning or a
message.

## 3. Run it on pull requests

### With the Action

[`marosoaie/steward-action`](https://github.com/marosoaie/steward-action)
uses the runner's Swift, trusts the checkout for git, fetches the history
Steward needs, caches the Dangerfile's build, runs it, and uploads its
report, so the workflow is short. Save this as
`.github/workflows/steward.yml`:

```yaml
name: Steward

on:
  pull_request:
    types: [opened, synchronize, reopened, edited, ready_for_review]

permissions:
  contents: read
  pull-requests: write

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  steward:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      # No v1 tag yet: pinned to a commit of the Action's main branch.
      - uses: marosoaie/steward-action@c606a4a637221b3d86c35e18c71aa4bbf6d9fecb
```

**Pinning the Action.** No swift-steward release has Steward yet, so the
Action has no `v1` tag either. Until it does, pin the Action by the full
SHA of a commit on its `main` branch, as above; a branch name would run
whatever lands there next. Once `v1` exists, use `@v1` instead.

With the package at `Dangerfile/` and its executable called `Dangerfile`,
as the template has them, the Action needs no `with:`; its
[README](https://github.com/marosoaie/steward-action#inputs) lists the
inputs for other layouts and tokens. It works the same on
`runs-on: macos-26`, with the selected Xcode's Swift.

### Without the Action

The same workflow, with the steps written out. It runs in the `swift:6.2`
container on Ubuntu:

```yaml
name: Steward

on:
  pull_request:
    types: [opened, synchronize, reopened, edited, ready_for_review]

permissions:
  contents: read
  pull-requests: write

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  steward:
    runs-on: ubuntu-latest
    container: swift:6.2
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      # The checkout belongs to the runner's user, not the container's, and
      # git won't read it until it's trusted.
      - run: git config --global --add safe.directory "$GITHUB_WORKSPACE"
      # The image's tag moves across patch releases, so the cache is keyed
      # on the compiler as well as on the pins.
      - id: swift
        run: echo "version=$(swift --version 2>&1 | sha256sum | cut -c1-16)" >> "$GITHUB_OUTPUT"
      - uses: actions/cache@v6
        with:
          path: Dangerfile/.build
          key: dangerfile-${{ runner.os }}-${{ runner.arch }}-${{ steps.swift.outputs.version }}-${{ hashFiles('Dangerfile/Package.resolved') }}
      - run: swift run --package-path Dangerfile
        env:
          GITHUB_TOKEN: ${{ github.token }}
```

On a macOS runner (`runs-on: macos-26`), leave out `container:` and the
`safe.directory` step: there the checkout and the job have the same user.
To keep the findings as JSON, as the Action does, run
`swift run --package-path Dangerfile Dangerfile --report steward-report.json`
and upload the file with `actions/upload-artifact`; a summary too long for
the comment then points at it.

The sections below explain each part of the workflow.

## Events

`types:` replaces `pull_request`'s default activity types, so it lists
them (`opened`, `synchronize`, `reopened`) and adds two:

- **`edited`**: the title, the description, or the base branch changed.
  Rules about them, such as the template's `description`, run again
  without a push.
- **`ready_for_review`**: a draft was marked ready. Rules that treat drafts
  differently, as `description` does, run again.

Steward refuses every other activity type (`labeled`, for one) and every
other event, `push` and `pull_request_target` included, and exits with
status 2. The pull request's data, labels included, comes from the event
as it was when the event fired.

## Permissions

- `contents: read` lets the job check out the repository, and
  `pull-requests: write` lets Steward create, update, and delete its
  summary comment. Set both explicitly: a new repository gives
  `GITHUB_TOKEN` read-only permissions by default. `issues: write` won't
  do instead: on a pull request, GitHub refuses it with 403.
- When posting fails, a missing permission included, Steward warns and the
  exit status still follows the findings; the job summary has them either
  way. The Action's `fail-on-post-error: true`, or
  `--fail-on-post-error` without it, makes a failed post fail the job.
- A pull request from a fork gets a read-only token: the rules run, and
  Steward posts nothing, with a notice that says so. Findings with a
  location still show in Files changed, since annotations need no token.
  A Dependabot pull request gets a read-only token too, and the post
  fails with a warning.
- With a personal access token or a GitHub App's token instead of the
  workflow's own, name the account the token posts as, so Steward finds
  the summary it posted before: the Action's `token` and `summary-author`
  inputs, or, without the Action, that token in `GITHUB_TOKEN` and
  `--summary-author <login>`.

## One run per pull request at a time

The `concurrency` group lets one run per pull request go on and cancels
the one before it. GitHub's comment API has no locking, so two runs
posting to one pull request at the same time can leave a duplicate
summary, or none until the next run; without the group, that's
unsupported. The group's name includes the workflow's, because groups
are shared by every workflow in the repository: two workflows that both
named theirs after the pull request would cancel each other. A run whose
pull request got a newer head in the meantime doesn't post at all, and
leaves the summary to the newer run.

## One Dangerfile per pull request

Every run on a pull request finds and replaces the same summary comment,
so several Dangerfiles posting to one pull request are unsupported: two
workflows, two jobs, or the entries of a matrix would overwrite each
other's summary. Keep all the rules in one Dangerfile, run by one job.

## History

Steward reads the pull request's changes as GitHub's Files changed tab
shows them, the diff from the merge base to the head, and maps the
build's line numbers from the merge commit to the head (see below). So
the checkout needs the head, the base, their merge base, and the merge
commit. `actions/checkout` fetches only the merge commit by default;
Steward then stops, saying the history is too shallow. `fetch-depth: 0`
fetches all of it. A partial history has to reach the merge base on every
path from the head: Steward refuses one whose cut could pass the base's
commits off as the pull request's. The Action needs no `fetch-depth`:
when the checkout is shallow, it fetches the whole history of the base
and head commits itself, with the credentials `actions/checkout` keeps.
In a private repository checked out with `persist-credentials: false`,
give the checkout `fetch-depth: 0` instead.

## The merge commit

In a `pull_request` run, `actions/checkout` checks out the merge commit
GitHub prepares (`refs/pull/<number>/merge`), the pull request merged
into the latest base, not the pull request's head:

- `context.git` is the pull request as reviewers see it, from the merge
  base to the head, and findings' line numbers are the head's.
- A rule that reads a file from disk, such as `Package.swift`, reads the
  merge commit's. That's the head's file unless the base changed the same
  file since the branch was cut.
- Build logs have the merge commit's line numbers. The diagnostics rule
  maps them to the head, and leaves out diagnostics on lines that only the
  base changed. A log made from another checkout, in another job for
  example, names its commit with `builtAt:`.
- A pull request with merge conflicts has no merge commit, and GitHub
  doesn't run its `pull_request` workflows until the conflicts are
  resolved.

## A dry run

Outside GitHub Actions, the Dangerfile is a dry run: it checks the branch
you're on, prints the summary, and never posts.

```sh
swift run --package-path Dangerfile
```

The pull request's changes are those from the merge base with
`origin/HEAD`, the remote's default branch, to `HEAD`. Options go after
the product's name, after `swift run`'s own:

```sh
swift run --package-path Dangerfile Dangerfile --base origin/develop
swift run --package-path Dangerfile Dangerfile --pull-request 42
swift run --package-path Dangerfile Dangerfile --help
```

Without `--pull-request`, there's no event to read the pull request from,
so Steward builds a placeholder from the head commit: its subject as the
title, its body as the description, the git user as the author, and no
labels. The summary says so. That's why the template's `description` rule
fails for a head commit with no body. `--pull-request <number>` reads the
real pull request from GitHub, with `GITHUB_TOKEN` if it's set, which a
private repository needs. The repository is `GITHUB_REPOSITORY`, or else
the `origin` remote's; set `GITHUB_REPOSITORY=owner/name` when `origin`
uses an SSH host alias.

A dry run exits as a run in Actions does, so it also works as a pre-push
check:

| Status | Meaning |
|---|---|
| 0 | No failures |
| 1 | At least one failure, a rule that threw included |
| 2 | Steward couldn't do its job, such as building the pull request's context |
