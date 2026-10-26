import Foundation
import StewardVersion
import Testing

/// The release version, which the CLI and Steward's reports read from one
/// place, so a release bumps it once.
@Suite("Release version")
struct VersionTests {
    @Test("steward --version prints the release version, the one Steward's reports name")
    func commandLine() throws {
        let output = String(decoding: try CommandLineTool.run(arguments: ["--version"]), as: UTF8.self)
        #expect(output == "\(Release.version)\n")
    }

    @Test("the release version is MAJOR.MINOR.PATCH, as the release workflow requires")
    func format() {
        let parts = Release.version.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } })
    }
}
