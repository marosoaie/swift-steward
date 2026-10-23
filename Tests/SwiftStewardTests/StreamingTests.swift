import Foundation
import Testing
@testable import BuildLogKit

/// Chunking invariants of the streaming log parsers. The diff parser's are
/// tested in the git-diff-parser library.
@Suite("Log streaming")
struct StreamingTests {
    @Test("over-long log lines truncate uniformly, independent of chunking")
    func giantLineCap() {
        // A diagnostic starting beyond the 1 MiB line cap is dropped, and
        // identically so for any chunking.
        let junk = String(repeating: "j", count: (1 << 20) + 100)
        let log = """
            \(junk) /repo/A.swift:1:1: warning: beyond the cap
            /repo/B.swift:2:2: warning: kept

            """
        let wholeLog = ClangStyleLogParser.diagnostics(in: log)
        #expect(wholeLog.map(\.path) == ["/repo/B.swift"])
        var logParser = ClangStyleLogParser()
        let logBytes = Array(log.utf8)
        var index = 0
        while index < logBytes.count {
            let end = min(index + (1 << 14), logBytes.count)
            logParser.consume(logBytes[index..<end])
            index = end
        }
        #expect(logParser.finalize() == wholeLog)
    }

    @Test("log parsing is chunk-size independent", arguments: [1, 3, 17, 4096])
    func logChunkedEquivalence(chunkSize: Int) {
        let log = """
        Compiling Swift Module 'App' (3 sources)
        /repo/Sources/App/Foo.swift:42:13: warning: unused ünïcode variable
        random noise without any marker
        /repo/Sources/App/Foo.swift:42:13: warning: unused ünïcode variable
        /repo/B.swift:1: error: boom
        """
        let bytes = Array(log.utf8)
        var parser = ClangStyleLogParser()
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            parser.consume(bytes[index..<end])
            index = end
        }
        let streamed = parser.finalize()
        #expect(streamed == ClangStyleLogParser.diagnostics(in: log))
        #expect(streamed.count == 2)
    }

    @Test("CRLF log lines parse identically to LF, even split between CR and LF")
    func crlf() {
        let lf = """
            /repo/A.swift:1:2: warning: first
            /repo/B.swift:3:4: error: second

            """
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let expected = ClangStyleLogParser.diagnostics(in: lf)
        #expect(expected.map(\.message) == ["first", "second"])
        #expect(ClangStyleLogParser.diagnostics(in: crlf) == expected)

        // One-byte chunks put every CR and its LF in different chunks.
        var parser = ClangStyleLogParser()
        Array(crlf.utf8).forEach { parser.consume([$0]) }
        #expect(parser.finalize() == expected)
    }
}
