/// A reader of a repository that holds no files: every read is
/// `.noSuchFile`.
struct NoRepositoryFiles: RepositoryFiles {
    func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
        .noSuchFile
    }
}
