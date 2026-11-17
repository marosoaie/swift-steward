import Steward

/// A reader of a repository that holds no files, for contexts that never
/// read one.
struct NoRepositoryFiles: RepositoryFiles {
    func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
        .noSuchFile
    }
}
