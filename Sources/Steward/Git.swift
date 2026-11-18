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
    /// even an explicit `--unified`; the next seven replace the repository
    /// `-C` names. The pathspec ones would make paths match as globs or
    /// regardless of case, and beside `--literal-pathspecs` git refuses to
    /// run at all.
    static let ignoredVariables: Set<String> = [
        "GIT_DIFF_OPTS", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
        "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",
    ]

    init(directory: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.directory = directory
        // A partial clone that fetches a missing object must fail, not
        // wait for a password. The system's attributes file has no `-c` to
        // shut it out, as the user's has (`diffConfiguration`).
        self.environment = environment
            .filter { !Self.ignoredVariables.contains($0.key) }
            .merging(["GIT_TERMINAL_PROMPT": "0", "GIT_ATTR_NOSYSTEM": "1"]) { $1 }
    }

    /// Standard error past this many bytes is dropped: it only goes into
    /// an error message.
    static let maximumErrorLength = 64 << 10

    /// Runs git with `arguments` and `input` as its standard input,
    /// handing its standard output to `consume` in chunks as it arrives,
    /// starting from `initial`.
    ///
    /// With a `launcher`, such as `xargs -0`, that runs instead, with git's
    /// command line after its own, and `input` is the launcher's.
    func run<Output: Sendable>(
        _ arguments: [String],
        input: [UInt8] = [],
        through launcher: [String] = [],
        into initial: Output,
        consume: @escaping @Sendable (inout Output, ArraySlice<UInt8>) -> Void
    ) async throws -> Outcome<Output> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = launcher + ["git", "-C", directory, "--no-pager"] + arguments
        process.environment = environment
        let standardOutput = Pipe()
        let standardError = Pipe()
        let standardInput = try input.isEmpty ? FileHandle.nullDevice : Self.handle(reading: input)
        defer { if !input.isEmpty { try? standardInput.close() } }
        process.standardInput = standardInput
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
        async let output = Blocking.run {
            try Self.read(standardOutput.fileHandleForReading, into: initial, consume: consume)
        }
        async let errors = Blocking.run {
            try Self.read(standardError.fileHandleForReading, into: [UInt8]()) { errors, chunk in
                errors.append(contentsOf: chunk.prefix(max(0, Self.maximumErrorLength - errors.count)))
            }
        }
        let (collected, message) = try await (output, errors)
        // Never nil: the handler yields before it finishes the stream.
        let status = await exits.first { _ in true } ?? -1
        #if !canImport(Darwin)
        // Returns at once, as git has exited, and is what lets
        // swift-corelibs-foundation free the Process: until it runs, the
        // Process and its run loop source retain each other.
        process.waitUntilExit()
        #endif
        return Outcome(output: collected, status: status, standardError: String(decoding: message, as: UTF8.self))
    }

    /// Runs git with `arguments` and returns its standard output, throwing
    /// `ContextError.gitFailed` when it exits with a failure.
    func output(_ arguments: [String]) async throws -> [UInt8] {
        let outcome = try await run(arguments, into: [UInt8]()) { $0.append(contentsOf: $1) }
        try Self.requireSuccess(outcome, arguments)
        return outcome.output
    }

    /// Runs git with `arguments` and then `trailing`, each one more
    /// argument exactly as its bytes are, and returns its standard output,
    /// throwing as `output(_:)` does.
    ///
    /// The trailing ones reach git through `xargs -0`, on its standard
    /// input: as arguments of `Process`, macOS rewrites text to its
    /// canonical decomposition, `é` into `e` and a combining accent and the
    /// Greek question mark into `;`, which no setting of git's undoes.
    /// None of them may hold a NUL, which ends one. Never with none, for
    /// which GNU's xargs would still run git once.
    func output(_ arguments: [String], appending trailing: [[UInt8]]) async throws -> [UInt8] {
        guard !trailing.isEmpty else { return try await output(arguments) }
        let outcome = try await run(
            arguments,
            input: trailing.flatMap { $0 + [0] },
            through: ["xargs", "-0"],
            into: [UInt8]()
        ) { $0.append(contentsOf: $1) }
        let message = outcome.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        // `env` and `xargs` exit with 127 when what they'd run isn't on
        // `PATH`; git itself never does. Any other failure, xargs reports
        // as its own, 1 or 123, after git's message.
        guard outcome.status != 127 else {
            throw ContextError.gitUnavailable("""
                it runs through xargs -0 to be given paths exactly, and one of the two isn't on PATH: \
                \(message)
                """)
        }
        guard outcome.status == 0 else {
            throw ContextError.gitFailed(
                arguments: arguments,
                status: outcome.status,
                message: "\(message) (the status is that of xargs -0, which ran git with the paths)"
            )
        }
        return outcome.output
    }

    /// A handle that reads `input` from a temporary file, which is gone
    /// from `parent` by the time it returns, whether it returns or throws.
    ///
    /// A file, not a pipe: once git exits, as it does on an error before
    /// reading all of its input, a write to its pipe raises SIGPIPE, which
    /// ends this process on macOS and Linux alike.
    static func handle(
        reading input: [UInt8],
        in parent: URL = FileManager.default.temporaryDirectory
    ) throws -> FileHandle {
        let directory = parent.appendingPathComponent("steward-git-input-\(UUID().uuidString)", isDirectory: true)
        // Before anything is written, so a write that fails partway, as on
        // a full disk, leaves nothing either. An open file outlives its
        // name, so nothing is left behind if this process ends early.
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            // A directory only this user may enter, so no one else can open
            // the file, even in a shared /tmp, however the file's mode
            // turns out: the paths are the repository's business.
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let url = directory.appendingPathComponent("input", isDirectory: false)
            try Data(input).write(to: url, options: .withoutOverwriting)
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw ContextError.gitUnavailable(
                "couldn't write its input to \(directory.path): \(error.localizedDescription)"
            )
        }
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
        // Now, not when the pipe is freed: on Linux a leaked Process keeps
        // its pipes, and `Process.run()` crashes once about 1,360
        // descriptors are open.
        defer { try? handle.close() }
        var output = initial
        // Imperative: each read decides whether there is another.
        while let chunk = try nextChunk(of: handle) {
            consume(&output, chunk)
        }
        return output
    }

    private static func nextChunk(of handle: FileHandle) throws -> ArraySlice<UInt8>? {
        try Blocking.withAutoreleasePool {
            guard let data = try handle.read(upToCount: 1 << 16), !data.isEmpty else { return nil }
            return ArraySlice(data)
        }
    }
}
