@testable import GitHubAPI
import Testing

/// One test per fix in Specs/github/fixes.yaml that corrects upstream, on the
/// fixture the fix names. Each fails once its fix is dropped and the client
/// regenerated: the operation then answers `.undocumented(statusCode:_:)`.
@Suite("Spec fixes: each fix's recorded response decodes as the fix declares it")
struct SpecFixRegressionTests {
    @Test("update-comment-404: updating a deleted comment decodes the declared 404")
    func updateDeletedComment() async throws {
        let output = try await Client.replaying("issues-update-comment.macos-update-deleted")
            .issuesUpdateComment(
                path: .init(owner: "marosoaie", repo: "swift-steward", commentId: 1),
                body: .json(.init(body: "gone"))
            )
        #expect(try output.notFound.body.json.message == "Not Found")
    }

    @Test("delete-comment-404: deleting a deleted comment decodes the declared 404")
    func deleteDeletedComment() async throws {
        let output = try await Client.replaying("issues-delete-comment.macos-delete-deleted")
            .issuesDeleteComment(path: .init(owner: "marosoaie", repo: "swift-steward", commentId: 1))
        #expect(try output.notFound.body.json.message == "Not Found")
    }
}
