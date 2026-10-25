import Foundation
@testable import GitHubAPI
import HTTPTypes
import OpenAPIRuntime
import Testing

/// The pieces `LiveGitHub` builds its client from, checked offline: nothing
/// here touches the network.
@Suite("The live tests' client stays read-only, keeps its token out of errors, and records faithfully")
struct LiveClientSupportTests {
    let serverURL = URL(string: "https://api.github.com")!
    let path = Operations.IssuesUpdateComment.Input.Path(owner: "marosoaie", repo: "swift-steward", commentId: 1)

    /// The error the client wrapped, or nil when `call` succeeded or threw
    /// something else.
    func underlyingError(of call: () async throws -> Void) async -> (any Error)? {
        do {
            try await call()
            return nil
        } catch let error as ClientError {
            return error.underlyingError
        } catch {
            return nil
        }
    }

    func capturingClient(_ middlewares: [any ClientMiddleware]) -> Client {
        Client(serverURL: serverURL, transport: CapturingTransport(), middlewares: middlewares)
    }

    @Test("the read-only guard refuses every write operation before it reaches the transport")
    func writesRefused() async {
        let client = capturingClient([ReadOnlyMiddleware()])
        let created = await underlyingError {
            _ = try await client.issuesCreateComment(
                path: .init(owner: path.owner, repo: path.repo, issueNumber: 21),
                body: .json(.init(body: "comment"))
            )
        }
        let updated = await underlyingError {
            _ = try await client.issuesUpdateComment(path: path, body: .json(.init(body: "comment")))
        }
        let deleted = await underlyingError {
            _ = try await client.issuesDeleteComment(
                path: .init(owner: path.owner, repo: path.repo, commentId: path.commentId)
            )
        }
        let methods = [created, updated, deleted].map { ($0 as? ReadOnlyMiddleware.Refusal)?.method }
        #expect(methods == [.post, .patch, .delete])
    }

    @Test("a GET goes through the guard with GitHub's headers, the token and the requested media type")
    func readHeaders() async throws {
        let client = capturingClient([
            ReadOnlyMiddleware(),
            GitHubHeadersMiddleware(token: "probe-token", accept: "application/vnd.github.full+json"),
        ])
        let error = await underlyingError {
            _ = try await client.pullsGet(path: .init(owner: path.owner, repo: path.repo, pullNumber: 20))
        }
        let request = try #require((error as? CapturingTransport.Sent)?.request)
        #expect(request.method == .get)
        #expect(request.path == "/repos/marosoaie/swift-steward/pulls/20")
        #expect(request.headerFields[.userAgent] == "swift-steward")
        #expect(request.headerFields[HTTPField.Name("x-github-api-version")!] == "2022-11-28")
        #expect(request.headerFields[.authorization] == "Bearer probe-token")
        #expect(request.headerFields[.accept] == "application/vnd.github.full+json")
    }

    @Test("without a token, no authorization header goes out, and the generated Accept stays")
    func anonymousHeaders() async throws {
        let client = capturingClient([GitHubHeadersMiddleware(token: nil)])
        let error = await underlyingError {
            _ = try await client.pullsGet(path: .init(owner: path.owner, repo: path.repo, pullNumber: 20))
        }
        let request = try #require((error as? CapturingTransport.Sent)?.request)
        #expect(request.headerFields[.authorization] == nil)
        #expect(request.headerFields[.accept] == "application/json")
    }

    // ClientError prints the request with every header; the middleware adds
    // the token to a copy the error never sees.
    @Test("a failed request's error shows the request's headers, but never the token")
    func tokenStaysOutOfErrors() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "pulls-get.macos-diff", withExtension: "http", subdirectory: "Fixtures")
        )
        let client = Client(
            serverURL: serverURL,
            transport: FixtureTransport(recorded: try RecordedResponse(contentsOf: fixture)),
            middlewares: [GitHubHeadersMiddleware(token: "probe-token")]
        )
        let error = await #expect(throws: ClientError.self) {
            _ = try await client.pullsGet(path: .init(owner: path.owner, repo: path.repo, pullNumber: 20))
        }
        let description = String(describing: try #require(error))
        #expect(description.contains("accept: application/json"))
        #expect(!description.contains("probe-token"))
    }

    @Test("a recording keeps only the kept headers, sorted, and reads back as it was written")
    func recordingRoundTrip() throws {
        let fields = [
            ("x-github-request-id", "D1E2:3F4A"),
            ("link", #"<https://api.github.com/repositories/1/issues/2/comments?page=2>; rel="next""#),
            ("x-oauth-scopes", "repo, workflow"),
            ("content-type", "application/json; charset=utf-8"),
            ("github-authentication-token-expiration", "2026-11-01 00:00:00 UTC"),
            ("etag", #"W/"abc""#),
        ].map { HTTPField(name: HTTPField.Name($0.0)!, value: $0.1) }
        let recorded = RecordedResponse(
            response: HTTPResponse(status: .ok, headerFields: HTTPFields(fields)),
            body: Data(#"[{"id":1}]"#.utf8)
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).http")
        defer { try? FileManager.default.removeItem(at: file) }
        try recorded.encoded.write(to: file)

        let read = try RecordedResponse(contentsOf: file)
        #expect(read.response.status == .ok)
        #expect(read.response.headerFields.map(\.name.canonicalName) == ["content-type", "etag", "link"])
        #expect(read.response.headerFields == recorded.response.headerFields)
        #expect(read.body == recorded.body)
    }

    // Not Bundle.urls(forResourcesWithExtension:subdirectory:): on Linux it
    // answers NSURLs, whose lastPathComponent is optional.
    static func fixtures() throws -> [String] {
        let folder = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".http") }
            .sorted()
        try #require(!names.isEmpty, "no recorded responses in \(folder.path)")
        return names
    }

    // The fixtures were recorded by the 3.2 spike's recorder, so they are the
    // oracle for the format this one writes.
    @Test("recording a fixture's response again reproduces the fixture byte for byte", arguments: try fixtures())
    func rerecording(fixture: String) async throws {
        let original = try #require(
            Bundle.module.url(forResource: fixture, withExtension: nil, subdirectory: "Fixtures")
        )
        let recorded = try RecordedResponse(contentsOf: original)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rerecording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let operation = String(fixture.prefix { $0 != "." })

        let (response, body) = try await RecordingMiddleware(directory: directory, scenario: "again").intercept(
            HTTPRequest(method: .get, scheme: "https", authority: "api.github.com", path: "/"),
            body: nil,
            baseURL: serverURL,
            operationID: operation.replacing("-", with: "/", maxReplacements: 1)
        ) { _, _, _ in
            (recorded.response, HTTPBody(recorded.body))
        }

        let written = directory.appendingPathComponent("\(operation).again.http")
        #expect(try Data(contentsOf: written) == Data(contentsOf: original))
        #expect(response == recorded.response)
        #expect(try await Data(collecting: #require(body), upTo: .max) == recorded.body)
    }
}
