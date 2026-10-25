import Foundation

/// The pull request the opt-in live write test may write to, read from the
/// environment (docs/github-api.md documents it):
///
/// - `STEWARD_LIVE_GITHUB_WRITE_TESTS=1` runs the test.
/// - `STEWARD_SANDBOX_REPOSITORY` names the repository as `owner/name`.
/// - `STEWARD_SANDBOX_PULL_REQUEST` is the pull request's number.
/// - `GITHUB_TOKEN` authenticates; it needs write access to the pull
///   request's comments.
struct LiveSandbox {
    static let isRequested = ProcessInfo.processInfo.environment["STEWARD_LIVE_GITHUB_WRITE_TESTS"] == "1"

    static let current: LiveSandbox? = LiveSandbox(environment: ProcessInfo.processInfo.environment)

    let owner: String
    let repository: String
    let pullRequest: Int
    let token: String

    init?(environment: [String: String]) {
        let parts = (environment["STEWARD_SANDBOX_REPOSITORY"] ?? "")
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              let pullRequest = environment["STEWARD_SANDBOX_PULL_REQUEST"].flatMap({ Int($0) }), pullRequest > 0,
              let token = environment["GITHUB_TOKEN"], !token.isEmpty else {
            return nil
        }
        owner = String(parts[0])
        repository = String(parts[1])
        self.pullRequest = pullRequest
        self.token = token
    }
}
