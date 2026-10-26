import Foundation
import GitDiffKit

extension Git {
    /// Options that fix the shape of `git diff`'s output, so a user's
    /// configuration (`diff.noprefix`, `color.ui=always`, an external diff
    /// tool, `diff.submodule=log`, `diff.interHunkContext`, `diff.algorithm`,
    /// `diff.ignoreSubmodules`, `diff.renameLimit`, …) can't break parsing,
    /// merge hunks, move them, hide a file, or split a rename. `-l1000` is
    /// git's default rename limit. Callers add the context lines they need.
    static let diffOptions = [
        "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative",
        "--src-prefix=a/", "--dst-prefix=b/", "-M", "-l1000", "--submodule=short", "--ignore-submodules=none",
        "--inter-hunk-context=0", "--diff-algorithm=myers", "--indent-heuristic", "-O/dev/null",
    ]

    /// Settings with no command-line option that change `git diff`'s bytes,
    /// set back to git's defaults: `core.quotePath=false` writes paths raw,
    /// `diff.suppressBlankEmpty` drops the space of a blank context line,
    /// and git diffs a file over `core.bigFileThreshold` as binary.
    static let diffConfiguration = [
        "-c", "core.quotePath=true", "-c", "diff.suppressBlankEmpty=false", "-c", "core.bigFileThreshold=512m",
    ]

    /// Whether the repository has the commit `sha`.
    func hasCommit(_ sha: String) async throws -> Bool {
        let arguments = ["rev-parse", "--verify", "--quiet", "--end-of-options", "\(sha)^{commit}"]
        let outcome = try await run(arguments, into: ()) { _, _ in }
        // Status 1: no such commit. `cat-file -e` would exit with 128 for
        // that too, the status of a directory that isn't a repository.
        if outcome.status == 1 { return false }
        try Self.requireSuccess(outcome, arguments)
        return true
    }

    /// Whether the repository is a shallow clone, whose history stops
    /// short of the root commits.
    func isShallow() async throws -> Bool {
        let output = try await output(["rev-parse", "--is-shallow-repository"])
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// The best common ancestor of two commits, or nil when the history
    /// the repository has holds none.
    func mergeBase(of first: String, and second: String) async throws -> String? {
        let arguments = ["merge-base", first, second]
        let outcome = try await run(arguments, into: [UInt8]()) { $0.append(contentsOf: $1) }
        // Status 1 with no output: no common ancestor. Anything else is an error.
        if outcome.status == 1, outcome.output.isEmpty { return nil }
        try Self.requireSuccess(outcome, arguments)
        return String(decoding: outcome.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams the diff from commit `old` to commit `new` through a parser
    /// whose consumer starts as `consumer`, and returns the consumer.
    func diff<Consumer: DiffEventConsumer & Sendable>(
        from old: String,
        to new: String,
        options: [String] = [],
        into consumer: Consumer,
        parsing parsingOptions: ParsingOptions
    ) async throws -> Consumer {
        let arguments = Self.diffConfiguration + ["diff"] + Self.diffOptions + options + [old, new, "--"]
        let parser = DiffEventParser(consumer: consumer, options: parsingOptions)
        let outcome = try await run(arguments, into: parser) { $0.consume($1) }
        try Self.requireSuccess(outcome, arguments)
        var finished = outcome.output
        return finished.finalize()
    }
}
