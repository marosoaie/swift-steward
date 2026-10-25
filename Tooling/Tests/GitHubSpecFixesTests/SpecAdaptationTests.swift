import GitHubSpecFixes
import Testing
import Yams

/// One test per fix in Specs/github/fixes.yaml that adapts the description
/// for the generator instead of correcting upstream, on the committed
/// generator input. Each fails once its fix is dropped and the client
/// regenerated: upstream's node is then back in Specs/github/openapi.yaml.
@Suite("Spec fixes: each adaptation holds in the committed generator input")
struct SpecAdaptationTests {
    let input: Node

    init() throws {
        input = try #require(try Yams.compose(yaml: RepositoryFixListTests.contents(of: "Specs/github/openapi.yaml")))
    }

    /// Fails, rather than passing vacuously, when the property has moved.
    func repositoryProperty(_ name: String) throws -> Node {
        let path = ["components", "schemas", "repository", "properties", name]
        return try #require(
            path.reduce(Optional(input)) { node, key in node?.value(forKey: key) },
            "no \(path.joined(separator: "/")) in the generator input"
        )
    }

    @Test("drop-x-webhooks: the generator input has no x-webhooks")
    func webhooksDropped() {
        #expect(input.value(forKey: "x-webhooks") == nil)
    }

    @Test("repository-has-downloads-undeprecated: Repository's has_downloads isn't deprecated")
    func hasDownloadsUndeprecated() throws {
        #expect(try repositoryProperty("has_downloads").value(forKey: "deprecated") == nil)
    }

    @Test("repository-squash-title-undeprecated: Repository's use_squash_pr_title_as_default isn't deprecated")
    func squashTitleUndeprecated() throws {
        #expect(try repositoryProperty("use_squash_pr_title_as_default").value(forKey: "deprecated") == nil)
    }
}
