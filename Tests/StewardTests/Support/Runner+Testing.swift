import Foundation
@testable import GitHubAPI
import OpenAPIRuntime
import PullRequestHosting
@testable import Steward

extension Runner {
    /// A runner for tests: `environment` on top of what git needs to run
    /// with its global and system configuration shut out, output recorded
    /// by `recording`, and hosts that send their requests to `transport`,
    /// which by default fails the test on any request.
    static func testing(
        _ arguments: [String] = [],
        environment: [String: String],
        directory: String,
        recording: RecordingConsole,
        transport: any ClientTransport = ForbiddenTransport()
    ) -> Runner {
        let process = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("GITHUB_") && !$0.key.hasPrefix("GIT_") }
        return Runner(
            arguments: arguments,
            program: "PullRequestChecks",
            environment: process.merging(TestRepository.environment) { $1 }.merging(environment) { $1 },
            currentDirectory: directory,
            console: recording.console,
            makeHost: { apiURL, owner, repository, token in
                GitHubHost(owner: owner, repository: repository, token: token, apiURL: apiURL, transport: transport)
            },
            makeToken: { "T0K3N" }
        )
    }
}
