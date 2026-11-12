import ArgumentParser
import Foundation
import GitDiffKit
import OutputEscaping

/// Reads a file (or stdin, for "-") in fixed-size chunks so inputs never
/// have to fit in memory.
func forEachChunk(ofInput pathArgument: String, _ body: (Data) -> Void) throws {
    let chunkSize = 4 << 20
    let handle: FileHandle
    if pathArgument == "-" {
        handle = .standardInput
    } else {
        guard let opened = FileHandle(forReadingAtPath: pathArgument) else {
            throw ValidationError("Cannot read '\(pathArgument)'.")
        }
        handle = opened
    }
    defer {
        if pathArgument != "-" { try? handle.close() }
    }
    do {
        while true {
            // Without a pool per iteration, the autoreleased Data chunks
            // returned by FileHandle.read all stay alive until the process
            // exits, and "streaming" quietly degrades to whole-file memory.
            let reachedEnd = try withAutoreleasePool {
                guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else {
                    return true
                }
                body(data)
                return false
            }
            if reachedEnd { break }
        }
    } catch {
        throw ValidationError("Failed reading '\(pathArgument)': \(error.localizedDescription)")
    }
}

/// Runs `body` inside an autorelease pool on Darwin, and directly elsewhere.
///
/// swift-corelibs-foundation has no autorelease pools: its `Data` is freed
/// as soon as the last reference goes, so there is nothing to drain.
func withAutoreleasePool<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(Darwin)
    try autoreleasepool(invoking: body)
    #else
    try body()
    #endif
}

extension ChangedLines {
    /// Parses the diff at `pathArgument` ("-" for stdin) without loading it
    /// into memory at once.
    init(streamingFrom pathArgument: String) throws {
        var parser = DiffParser()
        // GitDiffKit doesn't import Foundation, so it takes bytes, not Data.
        try forEachChunk(ofInput: pathArgument) { parser.consume([UInt8]($0)) }
        self = parser.finalize()
    }
}

/// `text` as a field of an output line people read: tabs as they are, and
/// any other control character, line breaks included, escaped, so a path
/// or a message from the input stays on its line and can't rewrite the
/// terminal.
func readable(_ text: String) -> String {
    text.escapingControlCharacters(except: ["\t"])
}

enum JSON {
    /// `value` as pretty-printed JSON. The GitHub Actions runner takes a
    /// `##[` anywhere in a line for a workflow command, so a string's `##[`
    /// is written `\u0023#[`, the same JSON value. Pretty-printing never
    /// starts a line with `::`, the other form, and escapes line breaks.
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
            .replacingOccurrences(of: "##[", with: "\\u0023#[")
    }
}

/// Buffered stdout so per-line output stays fast for huge results.
struct BufferedStandardOutput {
    private var buffer = ""

    mutating func writeLine(_ line: String) {
        buffer += line
        buffer += "\n"
        if buffer.utf8.count >= 1 << 16 {
            flush()
        }
    }

    mutating func flush() {
        if !buffer.isEmpty {
            // print (not fputs) keeps the build clean under strict memory
            // safety; it writes through the same buffered C stdout.
            print(buffer, terminator: "")
            buffer = ""
        }
    }
}
