# Security policy

Steward reads text that a pull request's author controls: the diff, the
file names, the title and description, and the logs that the pull
request's build and linters write. It is built so that none of it can
crash or hang a run, put words in the comment that no rule wrote, or
become a command to the CI runner.

## What Steward guarantees

- **Its parsers never trap and never throw.** Diffs go through GitDiffKit,
  which [has its own policy](https://github.com/marosoaie/git-diff-parser/blob/main/SECURITY.md).
  The log parsers skip a line they can't read, take time in proportion to
  the log's size, and read at most 1 MiB of a line, so a log without
  newlines can't grow their buffer. A SonarQube report, one JSON
  document, is read whole.
- **Text from the pull request stays text in the comment.** The summary
  escapes file names and diagnostics' messages, so they can't mention
  anyone, link an issue, or change the comment's layout. Rules escape
  the pull request's text with `Markdown.escaped(_:)` and
  `Markdown.codeSpan(_:)`.
- **Text from the pull request can't become a workflow command in
  Steward's log.** In GitHub Actions, annotations escape their properties
  and messages, and other text that could hold a command is written
  between `::stop-commands::` markers. `steward`'s annotations escape
  theirs too, and its JSON writes `##[` escaped.
- **Text from the pull request can't rewrite a terminal.** A dry run and
  `steward`'s text output write control characters as escapes, such as
  `\u{1B}`.
- **Git's configuration can't change what Steward reads.** Steward runs
  git with every option that shapes a diff pinned, and reads
  `.gitattributes` from the merge base, so a pull request can't use its
  own to hide the lines it changes.

## What Steward doesn't protect against

A pull request runs its own code: its workflow, its `Dangerfile/` and
its build decide its check. The
[quickstart's security model](docs/quickstart.md#security-model) says
what that means for branch protection and tokens.

## What counts as a vulnerability

Please report privately any input, such as a diff, a log, or a pull
request's text or files, that makes Steward or `steward`:

- crash, or take time out of proportion to the input's size;
- post Markdown that a rule didn't write, such as a mention or a link;
- write a workflow command that Steward didn't mean to write;
- read changed lines other than the ones GitHub's Files changed tab
  shows, in a way the pull request's author controls;
- reveal a token.

A pull request that changes its own Dangerfile or workflow to pass its
check isn't one: see the security model above.

## Reporting a vulnerability

Report it through GitHub's private vulnerability reporting: on the
repository's **Security** tab, choose **Report a vulnerability**. The
report stays private between you and the maintainer until a fix is
published. Include the input that triggers the problem, or a way to
make it, and the Steward version or commit.

## Supported versions

Steward is pre-1.0. Fixes land on `main` and ship in the next release;
earlier releases don't get backported fixes.
