extension Context {
    /// The file at `path` in the head commit or the merge base, read only
    /// when it's a regular file of at most `limit` bytes.
    ///
    /// Reads through `files`, so a rule sees the commit's file, never the
    /// checkout's: no symbolic link is followed, and the head's lines are
    /// the head's even when the checkout is a merge commit.
    ///
    /// ```swift
    /// switch try await context.contents(ofFileAt: "Package.swift") {
    /// case .bytes(let bytes): …
    /// case .noSuchFile, .notRegularFile, .tooLarge: …
    /// @unknown default: …
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - path: The file's path from the repository's root, as
    ///     `git.createdFiles` and the other lists give it. It names one
    ///     file exactly: `a*.swift` is the file of that name, not a glob.
    ///   - side: `.head`, the default, or `.mergeBase` for the file before
    ///     the pull request's changes.
    ///   - limit: The largest size, in bytes, that's read; a larger file
    ///     is `.tooLarge`. 1 MiB by default.
    /// - Returns: The bytes, or why there are none.
    /// - Throws: When the read itself fails: git can't run, the repository
    ///   lacks the file's contents, as a partial clone can, or the path is
    ///   longer than the system lets a command's argument be (on Linux,
    ///   128 KiB). What's at the path, whether nothing, a link, a
    ///   directory, or a large file, is an answer, not an error.
    public func contents(
        ofFileAt path: String,
        at side: Side = .head,
        limit: Int = FileContents.defaultLimit
    ) async throws -> FileContents {
        try await files.contents(ofFileAt: path, in: commit(at: side), limit: limit)
    }

    /// Whether a file in git can have `path` as its path: one from the
    /// repository's root, without an empty, `.` or `..` part, or a NUL.
    /// A run reads any other as `.noSuchFile`; StewardTesting's fake does
    /// too, and a fixture refuses a file given at one.
    package static func isValidPath(_ path: String) -> Bool {
        GitRepositoryFiles.treePath(path) != nil
    }
}
