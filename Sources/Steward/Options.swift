/// The command-line options of a Dangerfile's run (docs/danger.md,
/// section 6).
///
/// Parsed by hand: `Steward` is a library, and swift-argument-parser is
/// for the CLI target only. Each option takes its value as the next
/// argument or after `=`; a repeated option keeps its last value.
struct Options: Sendable, Equatable {
    /// `--base`: in a dry run, the commit the pull request merges into.
    var base: String?
    /// `--pull-request`: in a dry run, the pull request to read through the
    /// API instead of building a placeholder.
    var pullRequest: Int?
    /// `--report`: where to also write the report, as JSON.
    var reportPath: String?
    /// `--fail-on-post-error`: whether a failure to post the summary makes
    /// the run exit with status 2.
    var failsOnPostError = false
    /// `--help` or `-h`.
    var showsHelp = false

    init() {}

    init(arguments: [String]) throws(OptionsError) {
        var remaining = arguments[...]
        // Imperative: a cursor whose next step depends on what it just read.
        while let argument = remaining.popFirst() {
            let (name, attached) = Self.split(argument)
            switch name {
            case "--base":
                base = try Self.value(of: name, attached: attached, from: &remaining)
            case "--pull-request":
                let value = try Self.value(of: name, attached: attached, from: &remaining)
                guard let number = Int(value), number >= 1 else { throw .invalidPullRequest(value) }
                pullRequest = number
            case "--report":
                reportPath = try Self.value(of: name, attached: attached, from: &remaining)
            case "--fail-on-post-error" where attached == nil:
                failsOnPostError = true
            case "--help" where attached == nil, "-h" where attached == nil:
                showsHelp = true
            case _ where name.hasPrefix("-"):
                throw .unknownOption(argument)
            default:
                throw .unexpectedArgument(argument)
            }
        }
    }

    /// `--name=value` as its name and value; any other argument as itself
    /// and nil.
    private static func split(_ argument: String) -> (name: String, value: String?) {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
    }

    /// The option's value: after its `=`, or else the next argument,
    /// unless that one is an option itself, as in `--base --report out.json`.
    private static func value(
        of name: String,
        attached: String?,
        from remaining: inout ArraySlice<String>
    ) throws(OptionsError) -> String {
        if let attached {
            guard !attached.isEmpty else { throw .missingValue(name) }
            return attached
        }
        guard let next = remaining.first, !next.isEmpty, !next.hasPrefix("-") else { throw .missingValue(name) }
        remaining.removeFirst()
        return next
    }

    /// The help text, for a program called `program`.
    static func usage(program: String) -> String {
        """
        USAGE: \(program) [--base <ref>] [--pull-request <number>] [--report <path>] [--fail-on-post-error]

        Checks a pull request with this Dangerfile's rules. In a GitHub Actions pull_request \
        workflow (GITHUB_ACTIONS=true), the pull request comes from the event. Anywhere else \
        it's a dry run over the git checkout around the current directory: it prints the \
        summary and never posts.

        OPTIONS:
          --base <ref>             Dry run: the commit the pull request merges into. Default: \
        the origin remote's default branch (refs/remotes/origin/HEAD).
          --pull-request <number>  Dry run: read this pull request through the API, with \
        GITHUB_TOKEN when it's set, instead of a placeholder built from the head commit. The \
        repository is GITHUB_REPOSITORY, or else the origin remote's.
          --report <path>          Also write the report there, as JSON.
          --fail-on-post-error     Exit with status 2 when posting the summary fails.
          -h, --help               Show this help.

        EXIT STATUS:
          0  No failures.
          1  At least one failure, a rule that threw included.
          2  Steward couldn't do its job, such as building the pull request's context.

        """
    }
}
