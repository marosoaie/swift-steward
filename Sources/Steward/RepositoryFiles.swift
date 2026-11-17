/// Reads files as a commit holds them, for rules that look at a file's
/// contents.
///
/// `Context.files` is one. A real run's reads through git from the
/// repository at `run.workspace`, so what it returns is the commit's, not
/// the checkout's, whose tree may be another commit's and whose symbolic
/// links lead anywhere. A test passes a reader of its own.
///
/// A rule reads through `Context.contents(ofFileAt:at:limit:)`, which
/// names the commit for it.
public protocol RepositoryFiles: Sendable {
    /// The file at `path` in `commit`, read only when it's a regular file
    /// of at most `limit` bytes.
    ///
    /// - Parameters:
    ///   - path: The file's path from the repository's root, `/`-separated,
    ///     as `GitChanges` lists it. It names one file exactly: no glob,
    ///     no normalization, and no other spelling of the same name.
    ///   - commit: The SHA of the commit to read from.
    ///   - limit: The largest size, in bytes, that's read.
    /// - Returns: The bytes, or why there are none.
    /// - Throws: When the read itself fails, such as when the repository
    ///   lacks the commit or the file's contents, as a partial clone can.
    ///   What's at the path, whether nothing, a link, a directory, or a
    ///   large file, is an answer, not an error.
    func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents
}
