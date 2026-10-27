/// How a run ends (docs/danger.md, section 6). The worse of two wins: a
/// broken run says nothing reliable about the pull request.
enum ExitStatus: Int32, Sendable, Comparable {
    /// No finding is a failure.
    case clean = 0
    /// At least one finding is a failure, a rule that threw included.
    case failures = 1
    /// Steward couldn't do its job: bad options, no context, a report it
    /// couldn't write, a cancelled run, or, with `--fail-on-post-error`, a
    /// summary it couldn't post.
    case broken = 2

    static func < (lhs: ExitStatus, rhs: ExitStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
