import Foundation
@testable import GitHubAPI
import Testing

/// What Steward reads from an Actions `pull_request` event: the trigger, and
/// the pull request and repository with the REST API's schemas. The filter
/// keeps no webhook schemas, so one type serves the event and `pulls/get`.
private struct PullRequestEvent: Decodable {
    let action: String
    let number: Int
    let before: String?
    let after: String?
    let pullRequest: Components.Schemas.PullRequest
    let repository: Components.Schemas.Repository

    enum CodingKeys: String, CodingKey {
        case action, number, before, after
        case pullRequest = "pull_request"
        case repository
    }
}

/// Payloads Actions wrote to `GITHUB_EVENT_PATH` on swift-steward#21 on
/// 2026-10-24, when the 3.2 spike opened it and then pushed to it.
@Suite("GITHUB_EVENT_PATH payloads decode with the REST schemas")
struct EventPayloadTests {
    /// Matches the runtime's default ISO 8601 date transcoder.
    let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func event(_ name: String) throws -> PullRequestEvent {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "no fixture \(name).json"
        )
        return try decoder.decode(PullRequestEvent.self, from: Data(contentsOf: url))
    }

    @Test("an opened event decodes, naming its pull request and repository")
    func opened() throws {
        let event = try event("pull-request-event.opened")
        #expect(event.action == "opened")
        #expect(event.number == 21)
        #expect(event.pullRequest.number == event.number)
        #expect(event.pullRequest.draft == true)
        #expect(event.pullRequest.base.repo.fullName == event.repository.fullName)
        #expect(event.repository.fullName == "marosoaie/swift-steward")
    }

    @Test("a synchronize event decodes, its pull request's head at the pushed commit")
    func synchronize() throws {
        let event = try event("pull-request-event.synchronize")
        #expect(event.action == "synchronize")
        let after = try #require(event.after)
        #expect(event.before != after)
        #expect(event.pullRequest.head.sha == after)
    }

    @Test("an event's pull request carries what pulls/get answers for the same pull request")
    func sameAsPullsGet() async throws {
        let event = try event("pull-request-event.synchronize")
        let fetched = try await Client.replaying("pulls-get.macos-pr21")
            .pullsGet(path: .init(owner: "marosoaie", repo: "swift-steward", pullNumber: 21))
            .ok.body.json
        #expect(event.pullRequest.id == fetched.id)
        #expect(event.pullRequest.base.ref == fetched.base.ref)
        #expect(event.pullRequest.head.ref == fetched.head.ref)
    }
}
