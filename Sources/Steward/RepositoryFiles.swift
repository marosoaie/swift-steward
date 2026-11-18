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
    ///   lacks the commit; never because of what's at the path.
    func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents

    /// The files at `paths` in `commit`, in the order of `paths`, each
    /// read as `contents(ofFileAt:in:limit:)` reads it.
    ///
    /// A reader that can read many files at once gives its own: the git
    /// reader runs two git processes however many paths there are, where
    /// each single read runs three. Every file read is held until the call
    /// returns, so a caller bounds `paths.count × limit`. Without one, the
    /// paths are read in turn.
    ///
    /// - Throws: As a single read throws, for any of the paths.
    func contents(ofFilesAt paths: [String], in commit: String, limit: Int) async throws -> [FileContents]
}
