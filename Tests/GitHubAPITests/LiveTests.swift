import Foundation
@testable import GitHubAPI
import OpenAPIRuntime
import OpenAPIURLSession
import Testing

/// Where and how the live tests run, read from the environment:
///
/// - `STEWARD_SPIKE_LIVE_REPO` (`owner/repo`) enables them.
/// - `STEWARD_SPIKE_READ_PRS`: space-separated PRs to read.
/// - `STEWARD_SPIKE_WRITE_PR`: the PR to create, update and delete a comment
///   on. Only ever the spike's own draft PR.
/// - `GITHUB_TOKEN`: the token, never recorded.
/// - `STEWARD_SPIKE_RECORD_DIR`, `STEWARD_SPIKE_RECORD_LABEL`: where to record
///   responses, and the scenario prefix that tells recordings apart.
struct LiveEnvironment {
    let owner: String
    let repo: String
    let readPRs: [Int]
    let writePR: Int?
    let token: String?
    let recordDirectory: URL?
    let label: String

    static let current: LiveEnvironment? = {
        let environment = ProcessInfo.processInfo.environment
        let slug = environment["STEWARD_SPIKE_LIVE_REPO"]?
            .split(separator: "/", omittingEmptySubsequences: false) ?? []
        guard slug.count == 2 else {
            return nil
        }
        return LiveEnvironment(
            owner: String(slug[0]),
            repo: String(slug[1]),
            readPRs: (environment["STEWARD_SPIKE_READ_PRS"] ?? "").split(separator: " ").compactMap { Int($0) },
            writePR: environment["STEWARD_SPIKE_WRITE_PR"].flatMap { Int($0) },
            token: environment["GITHUB_TOKEN"].flatMap { $0.isEmpty ? nil : $0 },
            recordDirectory: environment["STEWARD_SPIKE_RECORD_DIR"].map { URL(fileURLWithPath: $0) },
            label: environment["STEWARD_SPIKE_RECORD_LABEL"] ?? "local"
        )
    }()

    /// A client on URLSessionTransport, recording as `<label>-<scenario>`.
    func client(_ scenario: String, token: String? = nil, accept: String? = nil) -> Client {
        let headers = GitHubHeadersMiddleware(token: token ?? self.token, accept: accept)
        let recording = recordDirectory.map { RecordingMiddleware(directory: $0, scenario: "\(label)-\(scenario)") }
        return Client(
            serverURL: URL(string: "https://api.github.com")!,
            transport: URLSessionTransport(),
            middlewares: [headers] + (recording.map { [$0] } ?? [])
        )
    }
}

@Suite("Live GitHub API (opt-in)", .serialized, .enabled(if: LiveEnvironment.current != nil))
struct LiveTests {
    let live = LiveEnvironment.current!

    @Test("pulls/get and issues/list-comments decode real PRs")
    func reads() async throws {
        for number in live.readPRs {
            let pull = try await live.client("pr\(number)")
                .pullsGet(path: .init(owner: live.owner, repo: live.repo, pullNumber: number))
            #expect(try pull.ok.body.json.number == number)
            let comments = try await live.client("pr\(number)")
                .issuesListComments(path: .init(owner: live.owner, repo: live.repo, issueNumber: number))
            _ = try comments.ok.body.json
        }
    }

    @Test("missing resources answer with the declared 404")
    func notFound() async throws {
        let pull = try await live.client("missing")
            .pullsGet(path: .init(owner: live.owner, repo: live.repo, pullNumber: 999_999))
        _ = try pull.notFound.body.json
        let comments = try await live.client("missing")
            .issuesListComments(path: .init(owner: live.owner, repo: live.repo, issueNumber: 999_999))
        _ = try comments.notFound.body.json
    }

    @Test("a bad token gets a 401, which no operation declares")
    func badToken() async throws {
        let pull = try await live.client("bad-token", token: "invalid")
            .pullsGet(path: .init(owner: live.owner, repo: live.repo, pullNumber: live.readPRs.first ?? 1))
        guard case .undocumented(statusCode: 401, _) = pull else {
            Issue.record("expected an undocumented 401, got \(pull)")
            return
        }
    }

    @Test("the diff media type is undeclared, so the client can't decode it")
    func diffMediaType() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await live.client("diff", accept: "application/vnd.github.diff")
                .pullsGet(path: .init(owner: live.owner, repo: live.repo, pullNumber: live.readPRs.first ?? 1))
        }
    }

    @Test(
        "a comment survives a create, list, update and delete round trip",
        .enabled(if: LiveEnvironment.current?.writePR != nil && LiveEnvironment.current?.token != nil)
    )
    func roundTrip() async throws {
        let number = try #require(live.writePR)
        let marker = "<!-- steward-spike \(live.label) -->"
        let created = try await live.client("created").issuesCreateComment(
            path: .init(owner: live.owner, repo: live.repo, issueNumber: number),
            body: .json(.init(body: "\(marker)\nStep 3.2 spike round trip; deleted right away."))
        )
        let comment = try created.created.body.json
        let path = Operations.IssuesUpdateComment.Input.Path(owner: live.owner, repo: live.repo, commentId: comment.id)
        do {
            let listed = try await live.client("listed", accept: "application/vnd.github.full+json")
                .issuesListComments(
                    path: .init(owner: live.owner, repo: live.repo, issueNumber: number),
                    query: .init(perPage: 100)
                )
            #expect(try listed.ok.body.json.contains { $0.id == comment.id && $0.bodyHtml != nil })
            let updated = try await live.client("updated").issuesUpdateComment(
                path: path,
                body: .json(.init(body: "\(marker)\nUpdated."))
            )
            #expect(try updated.ok.body.json.body == "\(marker)\nUpdated.")
        } catch {
            _ = try? await live.client("cleanup").issuesDeleteComment(
                path: .init(owner: path.owner, repo: path.repo, commentId: path.commentId)
            )
            throw error
        }
        let deleted = try await live.client("deleted").issuesDeleteComment(
            path: .init(owner: path.owner, repo: path.repo, commentId: path.commentId)
        )
        _ = try deleted.noContent

        let updateGone = try await live.client("update-deleted").issuesUpdateComment(
            path: path,
            body: .json(.init(body: "gone"))
        )
        guard case .undocumented(statusCode: 404, _) = updateGone else {
            Issue.record("expected an undocumented 404, got \(updateGone)")
            return
        }
        let deleteGone = try await live.client("delete-deleted").issuesDeleteComment(
            path: .init(owner: path.owner, repo: path.repo, commentId: path.commentId)
        )
        guard case .undocumented(statusCode: 404, _) = deleteGone else {
            Issue.record("expected an undocumented 404, got \(deleteGone)")
            return
        }
    }
}
