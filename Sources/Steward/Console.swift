import Foundation

/// Where a run writes: the summary to standard output in a dry run, the
/// log to standard error.
struct Console: Sendable {
    var writeOutput: @Sendable (String) -> Void
    var writeError: @Sendable (String) -> Void

    /// The process's own standard output and error, unbuffered, so the log
    /// shows each line as a long rule runs and nothing is lost on `exit`.
    static let standard = Console(
        writeOutput: { FileHandle.standardOutput.write(Data($0.utf8)) },
        writeError: { FileHandle.standardError.write(Data($0.utf8)) }
    )
}
