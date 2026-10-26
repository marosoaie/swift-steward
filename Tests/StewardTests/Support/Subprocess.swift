import Foundation

/// Runs the tools the tests build fixtures and oracles with (`git`), found
/// on `PATH`.
enum Subprocess {
    /// Returns the command's standard output, throwing with its standard
    /// error if it exits nonzero.
    ///
    /// Runs in `directory` when given, with `environment` added to the test
    /// process's own.
    static func output(
        of arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        // A file rather than a pipe: an undrained pipe can fill up and block
        // the child while standard output is drained.
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-tests-\(UUID().uuidString).stderr")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw FixtureError("could not create \(errorURL.path) to capture standard error")
        }
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let standardError = try FileHandle(forWritingTo: errorURL)
        defer { try? standardError.close() }
        process.standardError = standardError

        try process.run()
        // Drain before waiting, or a full pipe deadlocks the child.
        let output = try standardOutput.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw FixtureError("""
                \(arguments.joined(separator: " ")) exited with \(process.terminationStatus) \
                (is \(arguments[0]) installed and on PATH?): \(message.prefix(1000))
                """)
        }
        return output
    }
}
