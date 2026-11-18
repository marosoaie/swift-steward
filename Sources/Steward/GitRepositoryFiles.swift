/// Reads files from a local repository's commits through git, in two git
/// processes however many files a call reads: `ls-tree` for each path's
/// mode, object and size, then `cat-file --batch`, fed only the objects of
/// regular files within the limit. Past 64 KiB of paths, `ls-tree` runs
/// again for the rest.
///
/// A path's own bytes never reach `cat-file`'s input, which is one object
/// ID a line: a path may hold a line break, an ID can't.
struct GitRepositoryFiles: RepositoryFiles {
    let git: Git

    /// How many bytes of paths one `ls-tree` is given; more go to another.
    /// Far below any system's limit on a command's arguments, which the
    /// environment shares, and GNU xargs's 128 KiB.
    static let pathBytesPerCall = 64 << 10

    func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
        try await contents(ofFilesAt: [path], in: commit, limit: limit).first ?? .noSuchFile
    }

    func contents(ofFilesAt paths: [String], in commit: String, limit: Int) async throws -> [FileContents] {
        try await contents(ofFilesAt: paths, in: commit, limit: limit, pathBytesPerCall: Self.pathBytesPerCall)
    }

    /// The files at `paths` in `commit`, in the order of `paths`, each read
    /// only when it's a regular file of at most `limit` bytes, with
    /// `pathBytesPerCall` of paths for each `ls-tree`.
    func contents(
        ofFilesAt paths: [String],
        in commit: String,
        limit: Int,
        pathBytesPerCall: Int
    ) async throws -> [FileContents] {
        let names = paths.map(Self.treePath)
        let entries = try await entries(
            named: Set(names.compactMap(\.self)),
            in: commit,
            pathBytesPerCall: pathBytesPerCall
        )
        let readable = entries.values.filter { $0.isRegularFile && $0.size.map { $0 <= limit } ?? false }
        let objects = try await objects(Set(readable.map(\.object)).sorted())
        return try names.map { name in
            guard let name, let entry = entries[name] else { return .noSuchFile }
            guard entry.isRegularFile else { return .notRegularFile }
            // `ls-tree` says `BAD` for a blob it can't find, and succeeds:
            // a file to report, not to take for something other than one.
            guard let size = entry.size else {
                throw ContextError.gitFailed(
                    arguments: ["ls-tree", "--long"],
                    status: 0,
                    message: """
                        gave no size for \(String(decoding: name, as: UTF8.self)): the repository lacks its \
                        object \(entry.object), as a partial clone can
                        """
                )
            }
            guard size <= limit else { return .tooLarge(size: size) }
            guard let object = objects[entry.object] else {
                throw ContextError.gitFailed(
                    arguments: ["cat-file", "--batch"],
                    status: 0,
                    message: "printed no \(entry.object)"
                )
            }
            // `ls-tree` and `cat-file` disagree only when the repository
            // changes between them, or replaces objects.
            guard object.type == "blob" else { return .notRegularFile }
            return object.bytes.count <= limit ? .bytes(object.bytes) : .tooLarge(size: object.bytes.count)
        }
    }

    /// `path`'s bytes, or nil when no tree entry can have it as its path:
    /// it's empty or absolute, has an empty, `.` or `..` component, or
    /// holds a NUL, which no argument can. Git would refuse the first ones
    /// outright, failing every path of the call.
    static func treePath(_ path: String) -> [UInt8]? {
        let bytes = Array(path.utf8)
        let isValid = !bytes.contains(0)
            && bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).allSatisfy { component in
                !component.isEmpty && !component.elementsEqual(".".utf8) && !component.elementsEqual("..".utf8)
            }
        return isValid ? bytes : nil
    }

    /// The decimal number `digits` spell, or nil when they're not all
    /// digits or the number doesn't fit.
    static func decimal(_ digits: some Collection<UInt8>) -> Int? {
        guard !digits.isEmpty, digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        return Int(String(decoding: digits, as: UTF8.self))
    }
}
