import Foundation
@testable import Steward

/// The pull request the opt-in live summary comment test writes to, read
/// from the variables GitHubAPITests' live write test reads
/// (docs/github-api.md):
///
/// - `STEWARD_LIVE_GITHUB_WRITE_TESTS=1` runs the test.
/// - `STEWARD_SANDBOX_REPOSITORY` names the repository as `owner/name`.
/// - `STEWARD_SANDBOX_PULL_REQUEST` is the pull request's number.
/// - `GITHUB_TOKEN` authenticates; it needs write access to the pull
///   request's comments.
/// - `STEWARD_SANDBOX_SUMMARY_AUTHOR`, optional: the token's login, so that
///   only its comments count, as in a run.
struct LivePullRequest {
    static let isRequested = ProcessInfo.processInfo.environment["STEWARD_LIVE_GITHUB_WRITE_TESTS"] == "1"

    static let current: LivePullRequest? = LivePullRequest(environment: ProcessInfo.processInfo.environment)

    let repository: RepositoryName
    let number: Int
    let token: String
    let summaryAuthor: String?

    init?(environment: [String: String]) {
        guard let repository = RepositoryName(environment["STEWARD_SANDBOX_REPOSITORY"] ?? ""),
              let number = environment["STEWARD_SANDBOX_PULL_REQUEST"].flatMap({ Int($0) }), number > 0,
              let token = environment["GITHUB_TOKEN"], !token.isEmpty
        else { return nil }
        self.repository = repository
        self.number = number
        self.token = token
        summaryAuthor = environment["STEWARD_SANDBOX_SUMMARY_AUTHOR"].flatMap { $0.isEmpty ? nil : $0 }
    }
}
