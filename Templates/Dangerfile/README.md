# Dangerfile

This repository's pull request checks, run by
[Steward](https://github.com/marosoaie/swift-steward). The rules are in
[`Sources/Dangerfile/Checks.swift`](Sources/Dangerfile/Checks.swift), and
their tests in [`Tests/DangerfileTests`](Tests/DangerfileTests).

From the repository's root:

```sh
swift test --package-path Dangerfile   # the rules' tests
swift run --package-path Dangerfile    # a dry run on this branch: prints the summary, posts nothing
```

The [quickstart](https://github.com/marosoaie/swift-steward/blob/main/docs/quickstart.md)
has the workflow that runs it on pull requests, and
[Testing a Dangerfile's rules](https://github.com/marosoaie/swift-steward/blob/main/docs/rule-tests.md)
says how to test a rule.
