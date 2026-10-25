import Foundation
@testable import GitHubAPI
import OpenAPIRuntime

extension GitHubHost {
    /// The token the stubbed hosts send, to check it goes out and never
    /// shows up anywhere else.
    static let probeToken = "probe-token-3f9c1e"

    /// A host for marosoaie/swift-steward that sends its requests to
    /// `transport`.
    static func stubbed(
        _ transport: any ClientTransport,
        marker: SummaryMarker = .steward,
        summaryAuthor: String? = nil,
        commentsPerPage: Int = 100
    ) -> GitHubHost {
        GitHubHost(
            owner: "marosoaie",
            repository: "swift-steward",
            token: probeToken,
            apiURL: URL(string: "https://api.github.com")!,
            summaryAuthor: summaryAuthor,
            marker: marker,
            commentsPerPage: commentsPerPage,
            transport: transport
        )
    }
}
