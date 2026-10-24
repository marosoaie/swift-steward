import Foundation
@testable import GitHubAPI
import Testing

/// The `pull_request` member of an Actions event payload, decoded with the
/// REST API's schema instead of the webhook's.
private struct EventPullRequest: Decodable {
    let pullRequest: Components.Schemas.PullRequest

    enum CodingKeys: String, CodingKey {
        case pullRequest = "pull_request"
    }
}

/// Payloads Actions wrote to `GITHUB_EVENT_PATH` on the spike PR.
@Suite("GITHUB_EVENT_PATH payloads decode with the spec's schemas")
struct EventPayloadTests {
    /// Matches the runtime's default ISO 8601 date transcoder.
    let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func payload(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "no fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    @Test("an opened event decodes with the webhook schema and its pull request with the REST schema")
    func opened() throws {
        let data = try payload("pull-request-event.opened")
        let event = try decoder.decode(Components.Schemas.WebhookPullRequestOpened.self, from: data)
        let pullRequest = try decoder.decode(EventPullRequest.self, from: data).pullRequest
        #expect(event.number == 21)
        #expect(pullRequest.number == 21)
        #expect(pullRequest.draft == true)
    }

    @Test("a synchronize event decodes with the webhook schema and its pull request with the REST schema")
    func synchronize() throws {
        let data = try payload("pull-request-event.synchronize")
        let event = try decoder.decode(Components.Schemas.WebhookPullRequestSynchronize.self, from: data)
        let pullRequest = try decoder.decode(EventPullRequest.self, from: data).pullRequest
        #expect(event.before != event.after)
        #expect(pullRequest.head.sha == event.after)
    }
}
