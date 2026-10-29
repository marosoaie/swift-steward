import Foundation
@testable import Steward
import Testing

extension DiagnosticsRuleTests {
    @Test("a diagnostic two reports give alike is reported once, and one that differs in any part isn't")
    func duplicates() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        // As NetNewsWire's Mac and iOS builds both warned about one line of
        // a package they share.
        let macOS = try reports.write("""
            /workspace/Sources/A.swift:2:9: warning: value 'x' was never used
            /workspace/Sources/B.swift:1:1: warning: only on macOS

            """, to: "build-macos.log")
        let iOS = try reports.write("""
            /workspace/Sources/A.swift:2:9: warning: value 'x' was never used
            /workspace/Sources/A.swift:2:10: warning: value 'x' was never used
            /workspace/Sources/A.swift:2:9: error: value 'x' was never used
            /workspace/Sources/A.swift:2:9: warning: value 'y' was never used
            /workspace/Sources/A.swift:2:9: warning: value 'x' was never used [-Wunused]

            """, to: "build-ios.log")

        let (findings, log) = try await run([.xcodebuild(macOS), .xcodebuild(iOS)])
        // The matcher sorts each report's diagnostics, but not by severity.
        #expect(findings.map { "\($0.kind) \($0.text) \($0.location?.line ?? 0)" }.sorted() == [
            "failure value 'x' was never used 2",
            "warning only on macOS 1",
            "warning value 'x' was never used (`-Wunused`) 2",
            // Twice: once from each log, column 9 and then column 10.
            "warning value 'x' was never used 2",
            "warning value 'x' was never used 2",
            "warning value 'y' was never used 2",
        ])
        #expect(log.contains("""
            xcodebuild log \(iOS): 1 diagnostic on changed lines left out, the same as one an earlier report gave
            """))
        #expect(log.count { $0.contains("left out") } == 1)
    }

    @Test("a report's own repeats on changed lines stay, as filter keeps them")
    func repeatsInOneReport() async throws {
        let reports = try Reports()
        defer { reports.remove() }
        // One file under two spellings: the parser keeps both, and both
        // resolve to Sources/A.swift.
        let path = try reports.write("""
            /workspace/Sources/A.swift:2:1: warning: w
            Sources/A.swift:2:1: warning: w

            """, to: "build.log")

        let (findings, log) = try await run([.xcodebuild(path)])
        #expect(findings.count == 2)
        #expect(!log.contains { $0.contains("left out") })
    }
}
