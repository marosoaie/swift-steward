/// A console that records what a run writes, for a fixture run
/// (`Runner.run(_:in:postingTo:)`) and tests to read back.
struct RecordingConsole: Sendable {
    /// What a run wrote, and where.
    enum Entry: Sendable, Equatable {
        case output(String)
        case error(String)
    }

    let console: Console
    private let entries: AsyncStream<Entry>
    private let continuation: AsyncStream<Entry>.Continuation

    init() {
        let (entries, continuation) = AsyncStream<Entry>.makeStream()
        self.entries = entries
        self.continuation = continuation
        console = Console(
            writeOutput: { continuation.yield(.output($0)) },
            writeError: { continuation.yield(.error($0)) }
        )
    }

    /// Ends the recording and returns everything written, in order. Call
    /// it once, after the run.
    func finish() async -> [Entry] {
        continuation.finish()
        return await entries.reduce(into: []) { $0.append($1) }
    }

    /// Ends the recording and returns standard output and standard error,
    /// each as one string.
    func finishStreams() async -> (output: String, error: String) {
        await finish().reduce(into: ("", "")) { streams, entry in
            switch entry {
            case .output(let text): streams.0 += text
            case .error(let text): streams.1 += text
            }
        }
    }
}
