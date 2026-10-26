import Foundation

/// The DangerfileFixture executable the test build puts beside the tests,
/// run as its own process, as a workflow runs a Dangerfile.
enum FixtureDangerfile {
    /// What a run printed, and how it exited.
    struct Outcome {
        var status: Int32
        /// Standard output: a dry run's summary, or the usage.
        var output: String
        /// Standard error: the log.
        var log: String
    }

    /// The executable, found as SwiftStewardTests' `CommandLineTool` finds
    /// `steward`: `swift test` puts the tests' resource bundle in the
    /// products directory, Xcode the `.xctest` bundle.
    static var url: URL? {
        let directories = [Bundle.module.bundleURL.deletingLastPathComponent()] + Bundle.allBundles
            .filter { $0.bundleURL.pathExtension == "xctest" }
            .map { $0.bundleURL.deletingLastPathComponent() }
        return directories.map { $0.appendingPathComponent("DangerfileFixture") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs the fixture with `arguments` in `directory`, with exactly
    /// `environment`, and waits for it to exit.
    static func run(_ arguments: [String], environment: [String: String], in directory: URL) throws -> Outcome {
        guard let url else {
            throw FixtureError("""
                the DangerfileFixture executable wasn't built beside the tests; run swift build --build-tests
                """)
        }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        // Files rather than pipes, so neither stream can fill up and block
        // the child while the other is drained.
        let streams = try ["stdout", "stderr"].map { name in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("steward-tests-\(UUID().uuidString).\(name)")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw FixtureError("could not create \(url.path) to capture the fixture's \(name)")
            }
            return (url: url, handle: try FileHandle(forWritingTo: url))
        }
        defer {
            streams.forEach { stream in
                try? stream.handle.close()
                try? FileManager.default.removeItem(at: stream.url)
            }
        }
        process.standardOutput = streams[0].handle
        process.standardError = streams[1].handle
        try process.run()
        process.waitUntilExit()
        let texts = try streams.map { String(decoding: try Data(contentsOf: $0.url), as: UTF8.self) }
        return Outcome(status: process.terminationStatus, output: texts[0], log: texts[1])
    }
}
