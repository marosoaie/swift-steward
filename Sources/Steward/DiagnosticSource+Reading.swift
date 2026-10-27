import BuildLogKit
import Foundation

extension DiagnosticSource {
    /// What the source is, for people: "xcodebuild log", for example.
    var kind: String {
        switch tool {
        case .xcodebuild: "xcodebuild log"
        case .swiftLint: "SwiftLint output"
        case .swiftFormat: "SwiftFormat output"
        case .sonar: "SonarQube report"
        }
    }

    /// The report's diagnostics, parsed as it's read in chunks, off the
    /// cooperative pool, so a log of any size takes only the diagnostics'
    /// memory. A relative path starts from `workspace`.
    ///
    /// Throws when the file can't be read; content the parser doesn't
    /// recognize, a malformed report included, gives no diagnostics.
    func diagnostics(relativeTo workspace: String) async throws -> [Diagnostic] {
        let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workspace, isDirectory: true))
        let tool = tool
        return try await Blocking.run { try tool.diagnostics(readingFrom: url) }
    }
}

extension DiagnosticSource.Tool {
    func diagnostics(readingFrom url: URL) throws -> [Diagnostic] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var parser = makeParser()
        // Imperative: each read decides whether there is another.
        while let chunk = try Self.nextChunk(of: handle) {
            parser.consume(chunk)
        }
        return parser.finalize()
    }

    /// The parser `steward filter --tool` uses for this tool's output.
    private func makeParser() -> any LogParsing {
        switch self {
        case .xcodebuild: XcodeLogParser()
        case .swiftLint: SwiftLintLogParser()
        case .swiftFormat: SwiftFormatLogParser()
        case .sonar: SonarReportParser()
        }
    }

    private static func nextChunk(of handle: FileHandle) throws -> ArraySlice<UInt8>? {
        try Blocking.withAutoreleasePool {
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return nil }
            return ArraySlice(data)
        }
    }
}
