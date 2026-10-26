/// Why Steward couldn't build a run's context, which ends the run before
/// any rule runs.
enum ContextError: Error, Equatable, CustomStringConvertible {
    /// The commits a context needs, named in messages.
    enum CommitRole: String, Sendable {
        case base
        case head
        case built
    }

    case missingEnvironmentVariable(String)
    case invalidURL(variable: String, value: String)
    case unsupportedEvent(String)
    case unsupportedAction(String)
    case unreadableEventPayload(path: String, reason: String)
    case malformedEventPayload(path: String, reason: String)
    /// A value that should name a commit isn't a full SHA, so it never
    /// reaches git, where it could pass for an option.
    case invalidCommit(CommitRole, value: String)
    case missingCommit(CommitRole, sha: String)
    case noMergeBase(base: String, head: String, isShallow: Bool)
    /// The commits from the base to the head reach `boundary`, a commit
    /// whose parents the shallow clone lacks, so some are missing.
    case truncatedHistory(base: String, head: String, boundary: String)
    case gitFailed(arguments: [String], status: Int32, message: String)
    case gitUnavailable(String)

    /// What a person reading the run's log needs to know to fix it.
    var description: String {
        switch self {
        case .missingEnvironmentVariable(let name):
            "\(name) isn't set. GitHub Actions sets it in every workflow run."
        case .invalidURL(let variable, let value):
            "\(variable) is \"\(value)\", which isn't a URL."
        case .unsupportedEvent("pull_request_target"):
            """
            Steward doesn't run on pull_request_target events: they run in the base branch's \
            context, so the checkout isn't the pull request. Trigger the workflow on pull_request.
            """
        case .unsupportedEvent(let name):
            "Steward runs on pull_request events, not \(name)."
        case .unsupportedAction(let action):
            """
            Steward runs on pull_request events whose activity type is opened, synchronize, \
            reopened, or edited, not \(action). Leave the workflow's `types:` at its default, \
            or list only those.
            """
        case .unreadableEventPayload(let path, let reason):
            "Couldn't read the event payload at \(path): \(reason)"
        case .malformedEventPayload(let path, let reason):
            "The event payload at \(path) isn't a pull_request event's: \(reason)"
        case .invalidCommit(let role, let value):
            "The \(role.rawValue) commit \"\(value)\" isn't a full commit SHA."
        case .missingCommit(let role, let sha):
            """
            The \(role.rawValue) commit \(sha) isn't in the checkout: its history is too shallow. \
            \(Self.historyRemedy)
            """
        case .noMergeBase(let base, let head, isShallow: true):
            """
            The base commit \(base) and the head commit \(head) have no merge base in the \
            checkout: its history is too shallow. \(Self.historyRemedy)
            """
        case .truncatedHistory(let base, let head, let boundary):
            """
            The commits from the base \(base) to the head \(head) run past the start of the \
            checkout's history at \(boundary), so some are missing: its history is too shallow. \
            \(Self.historyRemedy)
            """
        case .noMergeBase(let base, let head, isShallow: false):
            "The base commit \(base) and the head commit \(head) share no history."
        case .gitFailed(let arguments, let status, let message):
            "git \(arguments.joined(separator: " ")) exited with status \(status): \(message)"
        case .gitUnavailable(let reason):
            "Couldn't run git: \(reason)"
        }
    }

    private static let historyRemedy = """
        Check out with `fetch-depth: 0`, or fetch the base and head commits with their \
        history back to the merge base.
        """
}
