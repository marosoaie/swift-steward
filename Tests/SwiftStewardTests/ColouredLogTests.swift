import Foundation
import Testing
@testable import BuildLogKit

/// Coloured build logs: the line parsers remove terminal escape sequences,
/// so a coloured log gives exactly the diagnostics of its plain twin.
///
/// The `coloured-logs` fixtures are one scratch package (a Swift target with
/// a warning and an error, a C target with a `#warning`) built by Swift
/// 6.4's default build system (Xcode 27.1): `swift-6.4.log` from a piped
/// `swift build`, which colours anyway, and `swift-6.4-no-color.log` from
/// `swift build --no-color-diagnostics`. Paths are rewritten to
/// `/ci/Scratch`, and the 4 KB frontend command line is elided.
/// `scratch.diff` adds the package's sources.
@Suite("Coloured logs")
struct ColouredLogTests {
    enum Tool: String, CaseIterable, Sendable {
        case generic, xcodebuild, swiftlint, swiftformat

        func diagnostics(in log: [UInt8], chunkSize: Int = .max) -> [Diagnostic] {
            var parser: any LogParsing =
                switch self {
                case .generic: ClangStyleLogParser()
                case .xcodebuild: XcodeLogParser()
                case .swiftlint: SwiftLintLogParser()
                case .swiftformat: SwiftFormatLogParser()
                }
            stride(from: 0, to: log.count, by: chunkSize).forEach { start in
                parser.consume(log[start...].prefix(chunkSize))
            }
            return parser.finalize()
        }
    }

    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/coloured-logs"))
    }

    static func bytes(of fixture: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try Self.fixture(fixture)))
    }

    @Test(
        "a coloured Swift 6.4 log gives the diagnostics of its plain twin, through each line parser",
        arguments: Tool.allCases
    )
    func colouredTwin(tool: Tool) throws {
        let coloured = try Self.bytes(of: "swift-6.4.log")
        #expect(coloured.contains(TerminalEscapes.escape))
        let plain = tool.diagnostics(in: try Self.bytes(of: "swift-6.4-no-color.log"))
        #expect(plain.count == 3)
        #expect(tool.diagnostics(in: coloured) == plain)
    }

    @Test("a coloured log's diagnostics come out clean, clang's rule flag included")
    func cleanDiagnostics() throws {
        #expect(Tool.xcodebuild.diagnostics(in: try Self.bytes(of: "swift-6.4.log")) == [
            Diagnostic(
                path: "/ci/Scratch/Sources/CScratch/probe.c", line: 4, column: 2,
                severity: .warning, message: "\"hand-rolled warning\"", rule: "-W#warnings"
            ),
            Diagnostic(
                path: "/ci/Scratch/Sources/Scratch/Error.swift", line: 2, column: 12,
                severity: .error, message: "cannot convert return expression of type 'String' to return type 'Int'"
            ),
            Diagnostic(
                path: "/ci/Scratch/Sources/Scratch/Warning.swift", line: 2, column: 9,
                severity: .warning,
                message: """
                    initialization of immutable value 'unused' was never used; consider replacing with \
                    assignment to '_' or removing it [#NoUsage]
                    """
            ),
        ])
    }

    @Test("a coloured log parses the same in chunks of any size", arguments: [1, 2, 3, 7, 64, 4096])
    func chunking(chunkSize: Int) throws {
        let coloured = try Self.bytes(of: "swift-6.4.log")
        let whole = Tool.xcodebuild.diagnostics(in: coloured)
        #expect(Tool.xcodebuild.diagnostics(in: coloured, chunkSize: chunkSize) == whole)
    }

    @Test("a log split into two chunks inside any escape sequence parses as a whole")
    func splitSequences() throws {
        // The lines that start with a path or an escape: the diagnostics
        // (CSI colours on the Swift ones and an OSC 8 hyperlink on the
        // warning, a coloured path on the C one) and the source snippets.
        let log = try Self.bytes(of: "swift-6.4.log")
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .filter { $0.first == TerminalEscapes.escape || $0.starts(with: Array("/ci/".utf8)) }
            .flatMap { Array($0) + [UInt8(ascii: "\n")] }
        let whole = Tool.xcodebuild.diagnostics(in: log)
        #expect(whole.count == 3)
        (0...log.count).forEach { split in
            var parser = XcodeLogParser()
            parser.consume(log[..<split])
            parser.consume(log[split...])
            #expect(parser.finalize() == whole, "split at byte \(split)")
        }
    }

    @Test("steward filter matches a coloured log as it does its plain twin, and fails on its warnings")
    func filter() throws {
        let diff = try Self.fixture("scratch.diff").path
        func filter(_ log: String) throws -> String {
            String(decoding: try CommandLineTool.run(
                arguments: [
                    "filter", try Self.fixture(log).path, "--diff", diff,
                    "--tool", "xcodebuild", "--format", "github", "--fail-on", "warning",
                ],
                exitCode: 1
            ), as: UTF8.self)
        }
        let plain = try filter("swift-6.4-no-color.log")
        #expect(plain.split(separator: "\n").count == 3)
        #expect(try filter("swift-6.4.log") == plain)
    }

    @Test(
        "sequences in the middle of a line parse like the plain line, wherever they sit",
        arguments: 0..<200
    )
    func insertedSequences(seed: UInt64) {
        let plain = Array("""
            /ci/Sources/Café/A.swift:12:5: warning: unused variable 'x' [-Wunused-variable]
            /ci/b.swift:3: error: “boom”

            """.utf8)
        let sequences = [
            "\u{1B}[0m", "\u{1B}[1;33m", "\u{1B}[38;5;196m", "\u{1B}[38:2::255:0:0m", "\u{1B}[m",
            "\u{1B}]8;;https://docs.swift.org/x\u{1B}\\", "\u{1B}]8;;\u{1B}\\", "\u{1B}]0;title\u{07}",
            "\u{1B}(B", "\u{1B}7", "\u{1B}[?25l",
        ].map { Array($0.utf8) }
        var generator = SeededGenerator(seed: seed)
        // Before any byte, a newline or a UTF-8 continuation byte too:
        // removal rejoins what a sequence splits.
        let coloured = plain.reduce(into: [UInt8]()) { coloured, byte in
            if Int.random(in: 0..<4, using: &generator) == 0 {
                coloured += sequences.randomElement(using: &generator) ?? []
            }
            coloured.append(byte)
        }
        let expected = Tool.xcodebuild.diagnostics(in: plain)
        #expect(expected.count == 2)
        #expect(Tool.xcodebuild.diagnostics(in: coloured) == expected)
        #expect(Tool.xcodebuild.diagnostics(in: coloured, chunkSize: 1) == expected)
    }

    @Test("each kind of escape sequence is removed whole", arguments: [
        ("\u{1B}[1;33mwarning: \u{1B}[1;39mmessage\u{1B}[0;0m", "warning: message"),
        ("\u{1B}[mreset", "reset"),
        ("\u{1B}[38;5;196mred\u{1B}[39m", "red"),
        ("\u{1B}[38:2::255:0:0mrgb", "rgb"),
        ("\u{1B}[?25lhidden cursor", "hidden cursor"),
        ("[#\u{1B}]8;;https://docs.swift.org/x\u{1B}\\NoUsage\u{1B}]8;;\u{1B}\\]", "[#NoUsage]"),
        ("\u{1B}]0;title\u{07}bell-terminated", "bell-terminated"),
        ("\u{1B}Pdevice control\u{1B}\\after", "after"),
        ("\u{1B}(B\u{1B}[mtput sgr0", "tput sgr0"),
        ("\u{1B}7saved\u{1B}8", "saved"),
        ("no escapes at all", "no escapes at all"),
    ])
    func wholeSequences(line: String, plain: String) {
        #expect(TerminalEscapes.removing(from: Array(line.utf8)[...]) == Array(plain.utf8))
    }

    @Test("a sequence cut short is removed as far as it goes, keeping the byte that ended it", arguments: [
        ("lone at the end\u{1B}", "lone at the end"),
        ("\u{1B}", ""),
        ("\u{1B}\u{1B}\u{1B}", ""),
        ("a\u{1B}[", "a"),
        ("a\u{1B}[12;", "a"),
        ("a\u{1B}[1;3\u{1B}[0mb", "ab"),
        ("a\u{1B}[1é", "aé"),
        ("a\u{1B}(", "a"),
        ("a\u{1B}(é", "aé"),
        ("a\u{1B}\u{7F}b", "a\u{7F}b"),
        ("a\u{1B}]8;;no terminator, so the rest of the line goes", "a"),
        ("a\u{1B}]8;;x\u{1B}[0mb", "ab"),
        ("a\u{1B}]8;;x\u{1B}", "a"),
    ])
    func truncatedSequences(line: String, plain: String) {
        #expect(TerminalEscapes.removing(from: Array(line.utf8)[...]) == Array(plain.utf8))
    }

    @Test("any bytes at all lose every ESC, keep the rest in order, and never trap", arguments: 0..<20)
    func arbitraryBytes(seed: UInt64) {
        let alphabet = Array("\u{1B}\u{1B}\u{1B}[]P_\\\u{07};:0129m(B 7w".utf8) + [0x7F, 0xC3, 0xFF]
        var generator = SeededGenerator(seed: seed)
        (0..<200).forEach { _ in
            let line = (0..<Int.random(in: 0...48, using: &generator)).compactMap { _ in
                alphabet.randomElement(using: &generator)
            }
            // A slice that doesn't start at zero, as the line splitter's don't.
            let padded = [UInt8(ascii: "x")] + line
            let plain = TerminalEscapes.removing(from: padded[1...])
            #expect(!plain.contains(TerminalEscapes.escape))
            var rest = line[...]
            let keepsOrder = plain.allSatisfy { byte in
                guard let found = rest.firstIndex(of: byte) else { return false }
                rest = rest[rest.index(after: found)...]
                return true
            }
            #expect(keepsOrder)
        }
    }

    @Test("damaged sequences never trap and leave the lines around them alone", arguments: [
        "\u{1B}", "\u{1B}[", "\u{1B}[1;3", "\u{1B}]8;;https://x", "\u{1B}]8;;\u{1B}", "\u{1B}\u{1B}", "\u{1B}(",
    ])
    func damagedLines(damage: String) {
        let diagnostic = "/ci/a.swift:1:2: warning: kept"
        let log = Array("\(damage)\n\(diagnostic)\n\(diagnostic)\(damage)\n\(damage)".utf8)
        let expected = [Diagnostic(path: "/ci/a.swift", line: 1, column: 2, severity: .warning, message: "kept")]
        #expect(Tool.generic.diagnostics(in: log) == expected)
        #expect(Tool.generic.diagnostics(in: log, chunkSize: 1) == expected)
    }

    @Test("an unterminated control string hides the rest of its line, as a terminal would")
    func unterminatedControlString() {
        #expect(Tool.generic.diagnostics(in: Array("""
            /ci/a.swift:1:2: \u{1B}]8;;https://x warning: hidden
            /ci/b.swift:3:4: warning: shown

            """.utf8)).map(\.path) == ["/ci/b.swift"])
    }
}

/// SplitMix64: a fixed sequence per seed, so a failure names its case.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
