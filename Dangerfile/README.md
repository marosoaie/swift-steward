# Dangerfile

This repository's own pull request checks, run by Steward through
[steward-action](https://github.com/marosoaie/steward-action) in
[pr.yml](../.github/workflows/pr.yml)'s `tests-and-diagnostics` job. The
rules are in [`Sources/Dangerfile/Checks.swift`](Sources/Dangerfile/Checks.swift),
and their tests in [`Tests/DangerfileTests`](Tests/DangerfileTests).

It's the [template](../Templates/Dangerfile) a user copies, except that it
depends on the checkout it sits in (`path: ".."`) rather than on
swift-steward's `main` branch, so every pull request is checked by its own
Steward. The root package never depends on it.

From the repository's root:

```sh
swift test --package-path Dangerfile   # the rules' tests
swift build 2>&1 | tee build.log && swiftlint lint --quiet | tee swiftlint.log
swift run --package-path Dangerfile    # a dry run on this branch: prints the summary, posts nothing
```

The diagnostics rule reads `build.log` and `swiftlint.log` at the
repository's root, as the job writes them, and a missing one is a failure.
