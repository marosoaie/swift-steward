import Foundation
import GitDiffKit
import Testing

/// Runs the command line tool on large, real diffs from notorious projects.
///
/// Fixtures resolve from a local cache, downloading from kernel.org /
/// github.com on a miss. Set `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS` to skip
/// the whole suite.
@Suite(
    "Real-world large diffs",
    .serialized,
    .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
)
struct RealWorldDiffTests {
    @Test(
        "the command line tool's per-file counts match git apply --numstat",
        arguments: RealWorldFixture.allCases
    )
    func matchesGitNumstat(fixture: RealWorldFixture) async throws {
        let diffURL = try await RealWorldFixtureStore.localDiffURL(for: fixture)
        let json = try CommandLineTool.run(arguments: ["changes", diffURL.path])
        let entries = try JSONDecoder().decode([ChangesEntry].self, from: json)

        let ours = Dictionary(entries.map { ($0.path, $0.lineCount) }, uniquingKeysWith: +)
        #expect(ours.count == entries.count, "the tool listed a path twice")
        let oracle = try GitNumstat.addedLineCounts(forDiffAt: diffURL)

        // Compare via an explicit mismatch list so a failure reports the
        // offending paths instead of dumping two 12k-entry dictionaries.
        let mismatched = Set(ours.keys).union(oracle.keys)
            .filter { ours[$0] != oracle[$0] }
            .sorted()
        #expect(ours.count == oracle.count)
        #expect(
            mismatched.isEmpty,
            "\(mismatched.count) files disagree with numstat; first: \(mismatched.prefix(5))"
        )
    }

    @Test("the command line tool handles the kernel diff end to end")
    func commandLineTool() async throws {
        let diffURL = try await RealWorldFixtureStore.localDiffURL(for: .linuxKernel)

        // `changes` over the full kernel diff.
        let json = try CommandLineTool.run(arguments: ["changes", diffURL.path])
        let entries = try JSONDecoder().decode([ChangesEntry].self, from: json)
        #expect(entries.count == 12_057)
        #expect(entries.reduce(0) { $0 + $1.lineCount } == 906_147)

        // `filter` with a synthetic log: one diagnostic on a changed line,
        // one far away from any change in the same file.
        let sample = try #require(entries.first)
        let changes = try Self.parseStreaming(contentsOf: diffURL)
        let changedLine = try #require(changes.ranges(in: sample.path).first?.lowerBound)
        let log = """
        /ci/checkout/\(sample.path):\(changedLine):1: warning: on a changed line
        /ci/checkout/\(sample.path):9000000:1: warning: far from any change
        """
        let logURL = RealWorldFixtureStore.cacheDirectory.appendingPathComponent("cli-smoke.log")
        try Data(log.utf8).write(to: logURL)
        let filtered = String(decoding: try CommandLineTool.run(
            arguments: ["filter", logURL.path, "--diff", diffURL.path, "--format", "text"]
        ), as: UTF8.self)
        #expect(filtered.contains("on a changed line"))
        #expect(!filtered.contains("far from any change"))
    }

    // MARK: Helpers

    /// Parses a diff file through the streaming interface in 4 MiB chunks,
    /// the same way the CLI does.
    static func parseStreaming(contentsOf url: URL) throws -> ChangedLines {
        var parser = DiffParser()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try readChunk(from: handle), !chunk.isEmpty {
            parser.consume([UInt8](chunk))
        }
        return parser.finalize()
    }

    private static func readChunk(from handle: FileHandle) throws -> Data? {
        #if canImport(Darwin)
        // FileHandle.read returns autoreleased Data; without a pool per read
        // every chunk lives until exit and the test reads the whole file.
        try autoreleasepool { try handle.read(upToCount: 4 << 20) }
        #else
        try handle.read(upToCount: 4 << 20)
        #endif
    }
}
