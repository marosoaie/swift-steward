import Foundation
import Testing

/// Pins the command line tool's exact output on real inputs, so every
/// platform has to print the same bytes.
///
/// Each case is a shell-like command line: `$kernel`, `$redis`, and `$sap`
/// stand for the real-world diffs, `Fixtures/…` for committed fixtures, and
/// `< path` feeds standard input. The fingerprints were taken from the macOS
/// build of `main` at 6fbb71a; Linux has to reproduce them byte for byte.
///
/// The `swift-argument-parser-1.5.0` fixtures are real tool output for
/// swift-argument-parser 1.5.0 (Apache 2.0), the new side of `$sap`, with
/// the checkout path rewritten to `/ci`:
/// - `xcodebuild.log`: `xcodebuild build -scheme ArgumentParser
///   SWIFT_STRICT_CONCURRENCY=complete` with Xcode 26.2.
/// - `swiftlint.log`: `swiftlint lint --quiet` (0.65, default rules) and
///   `swiftformat.log`: `swiftformat --lint --indent 2` (0.54.3), both over
///   `Sources/ArgumentParser/Parsable Types` and `Parsable Properties`.
/// - `sonar-issues.json` is hand-written in the shape of SonarQube's
///   `/api/issues/search` response, on lines `$sap` changes and lines it
///   doesn't.
@Suite(
    "Command line output",
    .serialized,
    .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
)
struct CommandLineOutputTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var command: String
        var exitCode: Int32 = 0
        /// Output length and 64-bit FNV-1a hash, as `length:hex`.
        var fingerprint: String

        var testDescription: String { command }
    }

    static let saplogs = "Fixtures/swift-argument-parser-1.5.0"

    static let cases: [Case] = [
        Case(command: "changes Fixtures/swift-pr-70000.diff", fingerprint: "4602:63c3e27e52a73606"),
        Case(command: "changes Fixtures/swift-pr-70000.diff --format text", fingerprint: "20481:516b0488996bdc87"),
        Case(command: "changes $sap", fingerprint: "87308:36c54895b814624e"),
        Case(command: "changes $sap --format text", fingerprint: "748598:ecfda19f85f4fdf4"),
        Case(command: "changes - < $sap", fingerprint: "87308:36c54895b814624e"),
        Case(command: "changes $redis", fingerprint: "854081:26e2fc956629eac"),
        Case(command: "changes $redis --format text", fingerprint: "3317316:6baac81f19044ae0"),
        Case(command: "changes $kernel", fingerprint: "5636156:870354130c3bb86f"),
        Case(command: "changes $kernel --format text", fingerprint: "43873626:1877f02d38576a4c"),
        Case(command: "filter \(saplogs)/xcodebuild.log --diff $sap", fingerprint: "1218:67bd1d5e79b63b53"),
        Case(
            command: "filter \(saplogs)/xcodebuild.log --diff $sap --tool xcodebuild",
            fingerprint: "1218:67bd1d5e79b63b53"
        ),
        Case(
            command: "filter \(saplogs)/xcodebuild.log --diff $sap --tool xcodebuild --format github",
            fingerprint: "911:5ce0fd2167c76771"
        ),
        Case(
            command: "filter \(saplogs)/xcodebuild.log --diff $sap --tool xcodebuild --format text",
            fingerprint: "851:7a5ec5a55ab4710b"
        ),
        Case(
            command: """
                filter \(saplogs)/xcodebuild.log --diff $sap --tool xcodebuild \
                --tolerance 5 --repo-root /ci/swift-argument-parser
                """,
            fingerprint: "2116:ef95c02fb808641d"
        ),
        Case(
            command: "filter \(saplogs)/swiftlint.log --diff $sap --tool swiftlint",
            fingerprint: "31841:393b433ff86943d9"
        ),
        Case(
            command: "filter \(saplogs)/swiftlint.log --diff $sap --tool swiftlint --format github",
            fingerprint: "22550:1820e8090ff28e7"
        ),
        Case(
            command: "filter - --diff $sap --tool swiftlint --format github < \(saplogs)/swiftlint.log",
            fingerprint: "22550:1820e8090ff28e7"
        ),
        Case(
            command: "filter \(saplogs)/swiftlint.log --diff $sap --tool swiftlint --format text",
            fingerprint: "20498:8ac67020fa1abea9"
        ),
        Case(
            command: "filter \(saplogs)/swiftlint.log --diff $sap --tool swiftlint --format text --fail-on warning",
            exitCode: 1,
            fingerprint: "20498:8ac67020fa1abea9"
        ),
        Case(
            command: "filter \(saplogs)/swiftformat.log --diff $sap --tool swiftformat",
            fingerprint: "126336:bbf50210cb2263b7"
        ),
        Case(
            command: "filter \(saplogs)/swiftformat.log --diff $sap --tool swiftformat --format github",
            fingerprint: "83849:56d41dbfba85b23f"
        ),
        Case(
            command: "filter \(saplogs)/swiftformat.log --diff $sap --tool swiftformat --format text",
            fingerprint: "74463:6d31e528db7b1319"
        ),
        Case(
            command: "filter \(saplogs)/sonar-issues.json --diff $sap --tool sonar",
            fingerprint: "1551:6ea44c2e227c88ce"
        ),
        Case(
            command: "filter \(saplogs)/sonar-issues.json --diff - --tool sonar < $sap",
            fingerprint: "1551:6ea44c2e227c88ce"
        ),
        Case(
            command: "filter \(saplogs)/sonar-issues.json --diff $sap --tool sonar --format github",
            fingerprint: "1075:1a671b879bec479d"
        ),
        Case(
            command: "filter \(saplogs)/sonar-issues.json --diff $sap --tool sonar --format text",
            fingerprint: "945:2e81153bdf34b79d"
        ),
    ]

    @Test("the command line tool prints the pinned bytes", arguments: cases)
    func output(of testCase: Case) async throws {
        var tokens = try await testCase.command.split(separator: " ").asyncMap(Self.resolve)
        var standardInput: URL?
        if let redirect = tokens.firstIndex(of: "<") {
            standardInput = URL(fileURLWithPath: tokens[tokens.index(after: redirect)])
            tokens.removeSubrange(redirect...)
        }
        let output = try CommandLineTool.run(
            arguments: tokens,
            standardInput: standardInput,
            exitCode: testCase.exitCode
        )
        #expect(
            Self.fingerprint(of: output) == testCase.fingerprint,
            "output changed; if that is intended on every platform, pin the new fingerprint"
        )
    }

    @Test("fingerprints tell apart outputs that differ in one byte or in length")
    func fingerprintsDiffer() {
        // The FNV-1a test vectors for "" and "a".
        #expect(Self.fingerprint(of: Data()) == "0:cbf29ce484222325")
        #expect(Self.fingerprint(of: Data("a".utf8)) == "1:af63dc4c8601ec8c")
        #expect(Self.fingerprint(of: Data("ab".utf8)) != Self.fingerprint(of: Data("ac".utf8)))
    }

    // MARK: Helpers

    static func fingerprint(of output: Data) -> String {
        let hash = output.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return "\(output.count):\(String(hash, radix: 16))"
    }

    private static func resolve(_ token: Substring) async throws -> String {
        let realWorld: [Substring: RealWorldFixture] = [
            "$kernel": .linuxKernel,
            "$redis": .redis,
            "$sap": .swiftArgumentParser,
        ]
        if let fixture = realWorld[token] {
            return try await RealWorldFixtureStore.localDiffURL(for: fixture).path
        }
        if token.hasPrefix("Fixtures/") {
            let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            return fixtures.deletingLastPathComponent().appendingPathComponent(String(token)).path
        }
        return String(token)
    }
}

extension Sequence {
    /// `map` with an asynchronous transform, applied in order.
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        // A plain loop: the standard library has no async map.
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}
