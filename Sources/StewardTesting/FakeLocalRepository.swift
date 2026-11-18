/// A repository in memory, for tests: the files of each commit, read as
/// `Context.localRepository` reads a real repository's.
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
/// context.localRepository = FakeLocalRepository([
///     context.git.head: ["Sources/App/Loader.swift": Array(SampleSource.loader.utf8)],
///     context.git.mergeBase: ["Sources/App/Loader.swift": Array(SampleSource.oldLoader.utf8)],
/// ])
/// ```
///
/// It knows a commit by its name exactly as a test gives it: one it holds
/// files at, or one it holds a line map from. A line map maps the lines of
/// the commit a build ran at to the head's, for the diagnostics rule's
/// `builtAt:` sources; `LineMap(diff:)` reads one.
public struct FakeLocalRepository: LocalRepository {
    /// The files by path's bytes, by commit.
    private let commits: [String: [[UInt8]: [UInt8]]]
    /// The maps to the head, by the commit they map from.
    private let lineMaps: [String: LineMap]

    /// Creates a repository holding `commits`' files, and `lineMaps`.
    ///
    /// - Parameters:
    ///   - commits: For each commit's SHA, its regular files' contents by
    ///     path, from the repository's root and `/`-separated, as
    ///     `GitChanges` lists them.
    ///   - lineMaps: For each commit a build ran at, the map from its lines
    ///     to the head's. Asked for a map to any other commit, the
    ///     repository gives this one.
    public init(_ commits: [String: [String: [UInt8]]], lineMaps: [String: LineMap] = [:]) {
        self.commits = commits.mapValues { files in
            Dictionary(files.map { (Array($0.key.utf8), $0.value) }) { first, _ in first }
        }
        self.lineMaps = lineMaps
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

    /// `name` when the repository holds files at a commit by that name, or
    /// a line map from it; otherwise nil.
    public func commit(named name: String) async throws -> String? {
        commits[name] != nil || lineMaps[name] != nil ? name : nil
    }

    /// `.identity` when `built` is `head`, or else the map the repository
    /// holds from `built`.
    ///
    /// - Throws: When it holds none.
    public func lineMap(from built: String, to head: String, attributesFrom mergeBase: String) async throws -> LineMap {
        guard built != head else { return .identity }
        guard let map = lineMaps[built] else { throw MissingLineMap(built: built, head: head) }
        return map
    }
}
