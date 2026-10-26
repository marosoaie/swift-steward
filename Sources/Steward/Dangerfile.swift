/// A Dangerfile: the rules a repository checks its pull requests with.
///
/// Conform one type in a package's executable target and mark it `@main`;
/// `main()` is the whole runner. `swift run` in a GitHub Actions
/// `pull_request` workflow checks the pull request; anywhere else it's a
/// dry run that prints the summary and never posts.
///
/// ```swift
/// import Steward
///
/// @main
/// struct PullRequestChecks: Dangerfile {
///     static var rules: [Rule] {
///         Rule("Changelog") { context in
///             guard !context.git.modifiedFiles.contains("CHANGELOG.md") else { return [] }
///             return [.warning("Add a CHANGELOG entry.")]
///         }
///     }
/// }
/// ```
///
/// The run exits with status 0 when no finding is a failure, 1 when one
/// is (a rule that throws counts), and 2 when Steward couldn't do its job,
/// for example when the event isn't a pull request's. Options:
///
/// - `--base <ref>`: in a dry run, the commit the pull request would merge
///   into; by default the `origin` remote's default branch.
/// - `--pull-request <number>`: in a dry run, read this pull request
///   through the API (with `GITHUB_TOKEN`, when set) instead of building a
///   placeholder from the head commit.
/// - `--report <path>`: also write the `Report` there, as JSON.
/// - `--fail-on-post-error`: exit with status 2 when posting the summary
///   fails, instead of only warning.
public protocol Dangerfile {
    /// The rules, in the order they run and their findings are shown.
    @RuleBuilder static var rules: [Rule] { get }
}
