import Foundation
@testable import GitHubAPI
import Testing

extension Client {
    /// A client that answers every request with `Fixtures/<fixture>.http`.
    static func replaying(_ fixture: String) throws -> Client {
        let url = try #require(
            Bundle.module.url(forResource: fixture, withExtension: "http", subdirectory: "Fixtures"),
            "no fixture \(fixture).http"
        )
        return Client(
            serverURL: URL(string: "https://api.github.com")!,
            transport: FixtureTransport(recorded: try RecordedResponse(contentsOf: url))
        )
    }
}
