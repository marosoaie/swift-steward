@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Release version")
struct ReleaseVersionTests {
    @Test("a new release version gets a warning at its file")
    func newVersion() async throws {
        let context = try Context.fixture(diff: SampleDiff.release)
        let findings = try await Checks.releaseVersion.evaluate(context)
        #expect(findings.map(\.kind) == [.warning])
        #expect(findings.map(\.location) == [Location(path: "Sources/StewardVersion/Release.swift")])
    }

    @Test("other changes leave it alone")
    func otherChanges() async throws {
        let context = try Context.fixture(diff: SampleDiff.source)
        #expect(try await Checks.releaseVersion.evaluate(context).isEmpty)
    }
}
