import Foundation
@testable import GitHubAPI
import OpenAPIRuntime
import PullRequestHosting
@testable import Steward

extension Runner {
    /// A runner for tests: `environment` on top of what git needs to run
    /// with its global and system configuration shut out, output recorded
    /// by `recording`, hosts that send their requests to `transport`,
    /// which by default fails the test on any request, and pauses that
    /// take no time.
    static func testing(
        _ arguments: [String] = [],
        environment: [String: String],
        directory: String,
        recording: RecordingConsole,
        transport: any ClientTransport = ForbiddenTransport()
    ) -> Runner {
        var runner = Runner(
            arguments: arguments,
            program: "PullRequestChecks",
            environment: TestRepository.runEnvironment(adding: environment),
            currentDirectory: directory,
            console: recording.console,
            makeHost: { apiURL, owner, repository, token, summaryAuthor in
                GitHubHost(
                    owner: owner,
                    repository: repository,
                    token: token,
                    apiURL: apiURL,
                    summaryAuthor: summaryAuthor,
                    transport: transport
                )
            },
            makeToken: { "T0K3N" }
        )
        runner.sleep = { _ in }
        return runner
    }
}
