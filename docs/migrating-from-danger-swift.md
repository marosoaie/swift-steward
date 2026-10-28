# Migrating from danger-swift

Steward does what danger-swift does: Swift rules check a pull request,
their findings appear in one comment, and a failure fails the check. It
differs in where the rules live and how they report. This page maps a
danger-swift Dangerfile, and how it runs, onto Steward. It names
danger-swift's API, as of 3.23.1, only to map it;
[danger.md](danger.md), section 7, has the reasons behind each
difference.

## What changes

- **No danger-js, no Node.** danger-swift evaluates the Dangerfile and
  hands the results to danger-js, which posts them. In Steward, the
  Dangerfile package's executable reads the pull request, runs the rules,
  and posts the comment itself.
- **A package, not a script.** The rules live in `Dangerfile/`, an
  ordinary SwiftPM package beside your own, built with `swift build` and
  tested with `swift test`.
- **Rules return findings.** There's no global `danger` and no global
  `warn`: a rule is a name and a closure from the pull request's context
  to the findings it returns.
- **GitHub Actions, on Linux or macOS runners.** Steward talks to GitHub
  only, and its CI mode needs an Actions `pull_request` event.

## Setting up

Follow the [quickstart](quickstart.md): it copies the template package to
`Dangerfile/`, and sets up the workflow. Then move your rules into
`Dangerfile/Sources/Dangerfile/Checks.swift`, and remove what danger-swift
needed:

- `Dangerfile.swift`, and any files it pulled in with `// fileImport:`;
  in Steward they're more files in the `Dangerfile` target.
- In your `Package.swift`, the `DangerDeps` library product, the
  `DangerDependencies` target, and the danger-swift and plugin packages.
- The danger-js install, and the step that ran `danger-swift ci` or the
  `danger/swift` Action.

## A Dangerfile, side by side

A danger-swift Dangerfile that asks for a changelog entry and refuses new
Objective-C files:

```swift
// Dangerfile.swift, with danger-swift
import Danger

let danger = Danger()
let git = danger.git

if (git.createdFiles + git.modifiedFiles).contains(where: { $0.hasPrefix("Sources/") }),
   !git.modifiedFiles.contains("CHANGELOG.md") {
    warn("Add a CHANGELOG entry.")
}
for file in git.createdFiles where file.hasSuffix(".m") {
    fail(message: "Write this file in Swift.", file: file, line: 1)
}
```

The same checks with Steward, each a rule:

```swift
// Dangerfile/Sources/Dangerfile/Checks.swift
import Steward

@main
struct Checks: Dangerfile {
    static var rules: [Rule] {
        changelog
        noObjectiveC
    }

    static let changelog = Rule("Changelog") { context in
        let git = context.git
        guard (git.createdFiles + git.modifiedFiles).contains(where: { $0.hasPrefix("Sources/") }),
              !git.modifiedFiles.contains("CHANGELOG.md")
        else { return [] }
        return [.warning("Add a CHANGELOG entry.")]
    }

    static let noObjectiveC = Rule("No new Objective-C") { context in
        context.git.createdFiles
            .filter { $0.hasSuffix(".m") }
            .map { .failure("Write this file in Swift.", at: Location(path: $0)) }
    }
}
```

Each rule is a static property, so a test can call it by name
([Testing a Dangerfile's rules](rule-tests.md)). Rules run in the order
`rules` lists them. The summary has a table each for failures, warnings,
and messages, then the Markdown, and in each, findings keep the rules'
order.

## The context

`danger` becomes the `context` each rule's closure receives. Steward
reads the pull request from the event that started the workflow, and the
changes from the local checkout, once, before the first rule runs.

| danger-swift | Steward | Notes |
|---|---|---|
| `danger.git.modifiedFiles`, `.createdFiles`, `.deletedFiles` | `context.git.modifiedFiles`, `.createdFiles`, `.deletedFiles` | `[String]`, repository-relative. Renamed files are in `modifiedFiles` under their new path, and in `renamedFiles` |
| `danger.git.commits` | `context.git.commits` | A `Commit` has `subject` and `body` rather than `message`, and a `sha` that's never `nil` |
| `danger.utils.diff(forFile:sourceBranch:)` | `context.git.file(at:)`, or `context.git.diff` | The pull request's whole diff, parsed once: files, hunks, and lines with their old and new numbers |
| `danger.github.pullRequest.title`, `.body`, `.number`, `.htmlUrl` | `context.pullRequest.title`, `.body`, `.number`, `.webURL` | `body` is empty rather than `nil` |
| `danger.github.pullRequest.user.login` | `context.pullRequest.author` | |
| `.additions`, `.deletions`, `.changedFiles`, `.commitCount` | `.additions`, `.deletions`, `.changedFiles`, `.commits` | Never `nil` |
| `.draft`, `.state`, `.isMerged` | `.isDraft`, `.state` (`.open`, `.closed`, `.merged`) | |
| `.base.ref`, `.base.sha`, `.base.repo` (and `head`) | `.base.name`, `.base.commit`, `.base.repository` (and `head`) | `repository` is `owner/name` |
| `danger.github.issue.labels` | `context.pullRequest.labels` | Label names, as they were when the event fired |
| `danger.github.commits` | `context.git.commits` | From git, not the API |
| `danger.utils.readFile(_:)` | Foundation, under `context.run.workspace` | The checkout is the merge commit, so a file the base branch also changed reads as merged |
| `danger.utils.exec(_:arguments:)`, `.spawn(_:arguments:)` | Foundation's `Process` | Rules are `async throws`: a tool that fails can throw |
| `danger.utils.environment` | `ProcessInfo.processInfo.environment` | |

## Messages, warnings, and failures

`message`, `warn`, `fail`, and `markdown` become findings a rule returns:
`.message("…")`, `.warning("…")`, `.failure("…")`, and `.markdown("…")`.

- A failure fails the check: the run exits with status 1. Warnings and
  messages don't.
- A rule that throws becomes a failure that names it, and the other
  rules still run.
- A rule can't read other rules' findings, as `danger.fails` and
  `danger.warnings` did. A test checks what a rule returns instead.
- A rule with several checks builds an array, or becomes several rules,
  so each finding names the rule that found it.
- When a later push fixes everything, Steward updates its comment to say
  there are no findings, rather than deleting it.

## Inline comments

`warn(message:file:line:)` and the other `file:line:` variants become a
finding with a location:

```swift
.warning("Avoid force unwrapping.", at: Location(path: "Sources/App.swift", line: 12))
```

In CI, Steward annotates a finding with a location, so it shows on its
line in the Files changed tab: a failure as an error, a warning as a
warning, and a message as a notice. One with a path but no line is
listed with the check run instead. The finding is also a row of the
summary comment that links to that line in the pull request's head
commit. The line is the head's, as the Files changed tab shows it, and
the path is repository-relative. GitHub shows 10 error, 10 warning, and
10 notice annotations per step; the summary comment keeps every finding.
A `markdown` finding, or one without a location, is in the summary only.

Steward doesn't post review comments on the diff, so
`suggestion(code:file:line:)` has no equivalent.

## Plugins become rules

A danger-swift plugin is a package whose functions read `Danger()` and
report with `warn` and `fail`, added through `DangerDeps` or an
`// package:` comment on an import. In Steward, a plugin is a package
with a library target that depends on the `Steward` product and returns
rules:

```swift
// A library of your own, depending on Steward
import Steward

public enum TeamRules {
    /// Fails a pull request that changes more than `limit` lines.
    public static func size(limit: Int) -> Rule {
        Rule("Size") { context in
            let changed = context.pullRequest.additions + context.pullRequest.deletions
            guard changed > limit else { return [] }
            return [.failure("This pull request changes \(changed) lines; split it below \(limit).")]
        }
    }
}
```

Add the package to `dependencies:` in `Dangerfile/Package.swift`, its
product to the `Dangerfile` target, and its rules to `rules`, beside your
own: `TeamRules.size(limit: 500)`. `rules` also takes an array, so a
plugin can hand over several rules at once. Until a swift-steward release
has Steward, such a package depends on swift-steward by branch, and the
Dangerfile has to depend on it by branch or revision too: SwiftPM doesn't
let a version requirement reach a branch dependency.

**SwiftLint.** danger-swift's `SwiftLint.lint(…)` runs SwiftLint itself.
Steward's built-in rule reads the report an earlier step of the workflow
wrote, and keeps the violations on lines the pull request changes:

```swift
Rule.diagnosticsOnChangedLines(in: [.swiftLint("swiftlint.log")])
```

Write `swiftlint lint`'s output, its default `xcode` reporter, to
`swiftlint.log` in a step before Steward's. `strict: true`, which makes
every violation fail, is `failingOn: .warning`. The same rule reads
`xcodebuild` and `swift build` output, SwiftFormat's, and SonarQube's
issues; the quickstart's
[diagnostics section](quickstart.md#2-write-the-rules) shows the
workflow steps.

## Running locally and in CI

| danger-swift | Steward |
|---|---|
| `danger-swift ci`, or the `danger/swift` Action | The [steward-action](https://github.com/marosoaie/steward-action), or the quickstart's [workflow without it](quickstart.md#without-the-action) |
| `danger-swift local` | `swift run --package-path Dangerfile`, outside Actions: a dry run of the branch you're on, against the `origin` remote's default branch (`--base <ref>` for another), which prints the summary and never posts |
| `danger-swift pr <url>` | Check out the pull request's branch, then add `--pull-request <number>` to the dry run, so the rules see its title, description, and labels |
| `danger-swift edit` | Open `Dangerfile/Package.swift` in Xcode |
| `DANGER_GITHUB_API_TOKEN` or `GITHUB_TOKEN` | `GITHUB_TOKEN`, which the Action sets from its `token` input |

Options to the Dangerfile go after its product name:
`swift run --package-path Dangerfile Dangerfile --help` lists them. A
dry run exits as a CI run does: 0 without failures, 1 with one, 2 when
Steward couldn't do its job. The workflow needs `pull-requests: write`
for the comment; the quickstart's [Permissions](quickstart.md#permissions)
section has the rest.

## What has no equivalent yet

- Review comments on the diff, and `suggestion(code:file:line:)`.
- GitHub's API from rules: `danger.github.api`, `reviews`, and
  `requestedReviewers`. The pull request's data comes from the event.
- GitLab and Bitbucket, and CI services other than GitHub Actions.
- Events other than `pull_request`, such as `push` or
  `pull_request_target`, and its activity types beyond `opened`,
  `synchronize`, `reopened`, `edited`, and `ready_for_review`.
- A comment on a pull request from a fork: its token is read-only, so
  the rules run and the job summary has the findings, but nothing is
  posted.
- Several Dangerfiles on one pull request, as danger-js's `--id` allows:
  they'd overwrite each other's summary.
- A dry run of a pull request without checking it out, as
  `danger-swift pr` does.
