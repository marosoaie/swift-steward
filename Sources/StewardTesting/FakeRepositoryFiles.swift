/// A repository in memory, for tests: the files of each commit, read as
/// `Context.files` reads a real repository's.
///
/// It answers as the git reader does for the paths it holds: a path is
/// matched byte for byte, so `./a.swift`, `a.swift/`, and a name's other
/// Unicode spelling name nothing; a path with files under it is a
/// directory, `.notRegularFile`; a file larger than the limit is
/// `.tooLarge`. It holds no symbolic links or submodules. A commit it
/// doesn't hold has no files, so every read there is `.noSuchFile`.
/// Swift's dictionaries take a name's precomposed and decomposed
/// spellings for one key, so it holds one of the two.
///
/// `Context.fixture(diff:files:)` makes one with the head's files. A test
/// that needs more, such as files at the merge base, gives the context
/// one of its own:
///
/// ```swift
/// var context = try Context.fixture(diff: SampleDiff.newLoader)
/// context.files = FakeRepositoryFiles([
///     context.git.head: ["Sources/App/Loader.swift": Array(SampleSource.loader.utf8)],
///     context.git.mergeBase: ["Sources/App/Loader.swift": Array(SampleSource.oldLoader.utf8)],
/// ])
/// ```
public struct FakeRepositoryFiles: RepositoryFiles {
    /// The files by path's bytes, by commit.
    private let commits: [String: [[UInt8]: [UInt8]]]

    /// Creates a repository holding `commits`' files.
    ///
    /// - Parameter commits: For each commit's SHA, its regular files'
    ///   contents by path, from the repository's root and `/`-separated,
    ///   as `GitChanges` lists them.
    public init(_ commits: [String: [String: [UInt8]]]) {
        self.commits = commits.mapValues { files in
            Dictionary(files.map { (Array($0.key.utf8), $0.value) }) { first, _ in first }
        }
    }

    /// The file at `path` in `commit`, read only when it's a regular file
    /// of at most `limit` bytes.
    public func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
        let files = commits[commit] ?? [:]
        let name = Array(path.utf8)
        if let bytes = files[name] {
            return bytes.count <= limit ? .bytes(bytes) : .tooLarge(size: bytes.count)
        }
        let directory = name + [UInt8(ascii: "/")]
        return !name.isEmpty && files.keys.contains { $0.starts(with: directory) } ? .notRegularFile : .noSuchFile
    }
}
