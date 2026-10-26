import Dispatch
import Foundation

/// Runs git in one repository.
///
/// The child process's pipes are drained on Dispatch's global queues, never
/// on Swift concurrency's cooperative pool, whose few threads a blocking
/// read would take away from everything else.
struct Git: Sendable {
    /// What a git command printed, and how it exited.
    struct Outcome<Output: Sendable>: Sendable {
        var output: Output
        var status: Int32
        var standardError: String
    }

    /// The repository's working tree, or the repository itself when bare.
    let directory: String
    /// What git runs with: the environment it was given, without the
    /// variables that would reshape its output or point it at another
    /// repository.
    let environment: [String: String]

    /// Variables no `-c` or option can override. `GIT_DIFF_OPTS` beats
    /// even an explicit `--unified`; the others replace the repository
    /// `-C` names.
    static let ignoredVariables: Set<String> = [
        "GIT_DIFF_OPTS", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
    ]

    init(directory: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.directory = directory
        // A partial clone that fetches a missing object must fail, not
        // wait for a password.
        self.environment = environment
            .filter { !Self.ignoredVariables.contains($0.key) }
            .merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
    }

    /// Standard error past this many bytes is dropped: it only goes into
    /// an error message.
    static let maximumErrorLength = 64 << 10

    /// Runs git with `arguments`, handing its standard output to `consume`
    /// in chunks as it arrives, starting from `initial`.
    func run<Output: Sendable>(
        _ arguments: [String],
        into initial: Output,
        consume: @escaping @Sendable (inout Output, ArraySlice<UInt8>) -> Void
    ) async throws -> Outcome<Output> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory, "--no-pager"] + arguments
        process.environment = environment
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
        // Not `waitUntilExit()`: on Darwin it never returns on a thread
        // other than the one that launched the process, which on the
        // cooperative pool may be any.
        let (exits, exit) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { process in
            exit.yield(process.terminationStatus)
            exit.finish()
        }
        do {
            try process.run()
        } catch {
            throw ContextError.gitUnavailable(error.localizedDescription)
        }
        // Both at once: while one pipe is read, a full other one would
        // block git.
        async let output = Self.offPool {
            try Self.read(standardOutput.fileHandleForReading, into: initial, consume: consume)
        }
        async let errors = Self.offPool {
            try Self.read(standardError.fileHandleForReading, into: [UInt8]()) { errors, chunk in
                errors.append(contentsOf: chunk.prefix(max(0, Self.maximumErrorLength - errors.count)))
            }
        }
        let (collected, message) = try await (output, errors)
        // Never nil: the handler yields before it finishes the stream.
        let status = await exits.first { _ in true } ?? -1
        return Outcome(output: collected, status: status, standardError: String(decoding: message, as: UTF8.self))
    }

    /// Runs git with `arguments` and returns its standard output, throwing
    /// `ContextError.gitFailed` when it exits with a failure.
    func output(_ arguments: [String]) async throws -> [UInt8] {
        let outcome = try await run(arguments, into: [UInt8]()) { $0.append(contentsOf: $1) }
        try Self.requireSuccess(outcome, arguments)
        return outcome.output
    }

    static func requireSuccess(_ outcome: Outcome<some Sendable>, _ arguments: [String]) throws {
        guard outcome.status == 0 else {
            throw ContextError.gitFailed(
                arguments: arguments,
                status: outcome.status,
                message: outcome.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func read<Output>(
        _ handle: FileHandle,
        into initial: Output,
        consume: (inout Output, ArraySlice<UInt8>) -> Void
    ) throws -> Output {
        var output = initial
        // Imperative: each read decides whether there is another.
        while let chunk = try nextChunk(of: handle) {
            consume(&output, chunk)
        }
        return output
    }

    private static func nextChunk(of handle: FileHandle) throws -> ArraySlice<UInt8>? {
        // A pool per read, or on Darwin every autoreleased chunk stays alive
        // until the read loop ends, and streaming holds the whole output.
        try withAutoreleasePool {
            guard let data = try handle.read(upToCount: 1 << 16), !data.isEmpty else { return nil }
            return ArraySlice(data)
        }
    }

    private static func withAutoreleasePool<Value>(_ body: () throws -> Value) rethrows -> Value {
        #if canImport(Darwin)
        try autoreleasepool(invoking: body)
        #else
        // swift-corelibs-foundation has no autorelease pools to drain.
        try body()
        #endif
    }

    private static func offPool<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
