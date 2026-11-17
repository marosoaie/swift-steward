import Foundation

/// Runs the tools the tests build fixtures and oracles with (`git`), found
/// on `PATH`.
enum Subprocess {
    /// How a command exited, with what it printed.
    struct Result {
        var status: Int32
        var output: Data
        var error: String
    }

    /// Returns the command's standard output, throwing with its standard
    /// error if it exits nonzero.
    ///
    /// Runs in `directory` when given, with `environment` added to the test
    /// process's own, and `input` as its standard input.
    static func output(
        of arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        input: Data = Data()
    ) throws -> Data {
        let result = try run(arguments, in: directory, environment: environment, input: input)
        guard result.status == 0 else {
            throw FixtureError("""
                \(arguments.joined(separator: " ")) exited with \(result.status) \
                (is \(arguments[0]) installed and on PATH?): \(result.error.prefix(1000))
                """)
        }
        return result.output
    }

    /// Runs the command as `output(of:in:environment:input:)` does, and
    /// returns how it exited, whatever the status, with what it printed.
    static func run(
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        input: Data = Data()
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        // A file rather than a pipe, as in `Git.run`: a write to the pipe of
        // a child that has exited would end the tests with SIGPIPE.
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-tests-\(UUID().uuidString).stdin")
        try input.write(to: inputURL)
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let standardInput = try FileHandle(forReadingFrom: inputURL)
        defer { try? standardInput.close() }
        process.standardInput = standardInput
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
        let message = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        return Result(status: process.terminationStatus, output: output, error: message)
    }
}
