import Foundation
@testable import GitHubAPI
import OpenAPIRuntime
import OpenAPIURLSession

/// Whether and how the opt-in live tests run, read from the environment
/// (docs/github-api.md documents it):
///
/// - `STEWARD_LIVE_GITHUB_TESTS=1` runs them.
/// - `GITHUB_TOKEN`, when set, authenticates them. They read public pull
///   requests only, so it's optional; it raises the rate limit from 60
///   requests an hour to 5,000.
/// - `STEWARD_LIVE_GITHUB_RECORD_DIR`, when set, records every response
///   there as `<operation>.live-<scenario>.http`, in the fixture format.
struct LiveGitHub {
    let token: String?
    let recordDirectory: URL?

    static let current: LiveGitHub? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["STEWARD_LIVE_GITHUB_TESTS"] == "1" else {
            return nil
        }
        return LiveGitHub(
            token: environment["GITHUB_TOKEN"].flatMap { $0.isEmpty ? nil : $0 },
            recordDirectory: environment["STEWARD_LIVE_GITHUB_RECORD_DIR"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        )
    }()

    /// A read-only client on the URLSession transport. `token` replaces the
    /// environment's.
    func client(_ scenario: String, token: String? = nil, accept: String? = nil) -> Client {
        let middlewares: [any ClientMiddleware] = [
            ReadOnlyMiddleware(),
            GitHubHeadersMiddleware(token: token ?? self.token, accept: accept),
        ] + (recordDirectory.map { [RecordingMiddleware(directory: $0, scenario: "live-\(scenario)")] } ?? [])
        return Client(
            serverURL: URL(string: "https://api.github.com")!,
            transport: URLSessionTransport(),
            middlewares: middlewares
        )
    }

    /// A read-only host on the URLSession transport, recording to
    /// `recordDirectory` when one is given, else to the environment's.
    func host(
        owner: String,
        repository: String,
        scenario: String,
        token: String? = nil,
        marker: SummaryMarker = .steward,
        commentsPerPage: Int = 100,
        recordDirectory: URL? = nil
    ) -> GitHubHost {
        GitHubHost(
            owner: owner,
            repository: repository,
            token: token ?? self.token,
            apiURL: URL(string: "https://api.github.com")!,
            marker: marker,
            commentsPerPage: commentsPerPage,
            transport: URLSessionTransport(),
            middlewares: [ReadOnlyMiddleware()] + ((recordDirectory ?? self.recordDirectory).map {
                [RecordingMiddleware(directory: $0, scenario: "live-\(scenario)")]
            } ?? [])
        )
    }
}
