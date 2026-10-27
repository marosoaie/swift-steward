@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Description")
struct DescriptionTests {
    @Test("a pull request ready for review without a description fails", arguments: ["", " \n\t"])
    func missing(body: String) async throws {
        let context = try Context.fixture(diff: SampleDiff.sources, pullRequest: .fixture(body: body))
        let findings = try await Checks.description.evaluate(context)
        #expect(findings == [.failure("Describe what this pull request changes and why.")])
    }

    @Test("a draft needs no description yet")
    func draft() async throws {
        let context = try Context.fixture(diff: SampleDiff.sources, pullRequest: .fixture(isDraft: true))
        let findings = try await Checks.description.evaluate(context)
        #expect(findings.isEmpty)
    }

    @Test("a described pull request passes")
    func described() async throws {
        let context = try Context.fixture(
            diff: SampleDiff.sources,
            pullRequest: .fixture(body: "Greets the user before printing.")
        )
        let findings = try await Checks.description.evaluate(context)
        #expect(findings.isEmpty)
    }
}
