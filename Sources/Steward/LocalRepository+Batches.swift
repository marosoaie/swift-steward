extension LocalRepository {
    /// The files at `paths` in `commit`, read one at a time through
    /// `contents(ofFileAt:in:limit:)`: a reader's batch read, when it
    /// gives none of its own.
    public func contents(ofFilesAt paths: [String], in commit: String, limit: Int) async throws -> [FileContents] {
        var contents: [FileContents] = []
        // Imperative: each read awaits, which `map` can't.
        for path in paths {
            try await contents.append(self.contents(ofFileAt: path, in: commit, limit: limit))
        }
        return contents
    }
}
