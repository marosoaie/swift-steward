import Foundation
import GitHubAPI
import PullRequestHosting

extension Context {
    /// The `pull_request` activity types Steward runs on (docs/danger.md,
    /// section 2): `edited` for rules about the title and description.
    static let supportedActions: Set<String> = ["opened", "synchronize", "reopened", "edited"]

    /// Builds the context of a GitHub Actions run from its environment:
    /// the pull request from the event payload, with no API call, and the
    /// git data from the checkout at `GITHUB_WORKSPACE`.
    ///
    /// Needs the base and head commits from the payload, their merge
    /// base, and the built commit, `GITHUB_SHA`, in the checkout; a
    /// shallow one throws `ContextError.missingCommit` or
    /// `ContextError.noMergeBase`.
    static func actions(environment: [String: String]) async throws -> Context {
        let variables = ActionsVariables(environment)
        let eventName = try variables.required("GITHUB_EVENT_NAME")
        guard eventName == "pull_request" else { throw ContextError.unsupportedEvent(eventName) }
        let event = try PullRequestEvent(contentsOf: variables.required("GITHUB_EVENT_PATH"))
        guard supportedActions.contains(event.action) else { throw ContextError.unsupportedAction(event.action) }

        let workspace = try variables.required("GITHUB_WORKSPACE")
        let base = try ActionsVariables.commit(event.pullRequest.base.commit, role: .base)
        let head = try ActionsVariables.commit(event.pullRequest.head.commit, role: .head)
        let built = try ActionsVariables.commit(variables.required("GITHUB_SHA"), role: .built)
        let apiURL = try variables.url("GITHUB_API_URL", default: "https://api.github.com")
        let serverURL = try variables.url("GITHUB_SERVER_URL", default: "https://github.com")

        let git = Git(directory: workspace)
        try await requireCommit(base, role: .base, in: git)
        try await requireCommit(head, role: .head, in: git)
        try await requireCommit(built, role: .built, in: git)
        return Context(
            pullRequest: event.pullRequest,
            git: try await GitChanges(base: base, head: head, git: git),
            run: Run(
                mode: .actions,
                workspace: workspace,
                builtCommit: built,
                lineMap: try await LineMap(built: built, head: head, git: git),
                apiURL: apiURL,
                serverURL: serverURL
            )
        )
    }

    private static func requireCommit(_ sha: String, role: ContextError.CommitRole, in git: Git) async throws {
        guard try await git.hasCommit(sha) else { throw ContextError.missingCommit(role, sha: sha) }
    }
}

private extension PullRequestEvent {
    init(contentsOf path: String) throws {
        let payload: Data
        do {
            payload = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ContextError.unreadableEventPayload(path: path, reason: error.localizedDescription)
        }
        do {
            try self.init(payload: payload)
        } catch let error as DecodingError {
            throw ContextError.malformedEventPayload(path: path, reason: error.summary)
        }
    }
}
