import Foundation

extension TestRepository {
    /// A path to put straight into the index, with no file in the working
    /// tree: so its name may hold any byte but NUL, such as a line break
    /// or bytes that aren't UTF-8, which macOS's file system refuses.
    struct IndexEntry {
        /// `100644`, `100755`, `120000` for a symbolic link, `160000` for
        /// a submodule, or `0` to remove the path.
        var mode: String
        var path: [UInt8]
        /// The blob's or the submodule commit's ID.
        var object: String

        /// A regular file holding `contents`, written into `repository`.
        static func file(
            _ path: String,
            _ contents: [UInt8],
            executable: Bool = false,
            in repository: TestRepository
        ) throws -> IndexEntry {
            try file(Array(path.utf8), contents, executable: executable, in: repository)
        }

        /// A regular file at a path given as bytes.
        static func file(
            _ path: [UInt8],
            _ contents: [UInt8],
            executable: Bool = false,
            in repository: TestRepository
        ) throws -> IndexEntry {
            IndexEntry(mode: executable ? "100755" : "100644", path: path, object: try repository.blob(contents))
        }

        /// A symbolic link to `target`.
        static func link(_ path: String, to target: String, in repository: TestRepository) throws -> IndexEntry {
            IndexEntry(mode: "120000", path: Array(path.utf8), object: try repository.blob(Array(target.utf8)))
        }

        /// A submodule at `commit`, which the repository needn't have.
        static func submodule(_ path: String, at commit: String) -> IndexEntry {
            IndexEntry(mode: "160000", path: Array(path.utf8), object: commit)
        }

        /// The removal of `path` from the index.
        static func removal(_ path: String) -> IndexEntry {
            IndexEntry(mode: "0", path: Array(path.utf8), object: String(repeating: "0", count: 40))
        }
    }

    /// Writes `contents` as a blob and returns its ID.
    func blob(_ contents: [UInt8]) throws -> String {
        let output = try Subprocess.output(
            of: ["git", "-C", path, "hash-object", "-w", "--stdin"],
            environment: Self.environment,
            input: Data(contents)
        )
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts `entries` into the index, their paths byte for byte.
    func stage(_ entries: [IndexEntry]) throws {
        let records = entries.flatMap { entry -> [UInt8] in
            Array("\(entry.mode) \(entry.object)\t".utf8) + entry.path + [0]
        }
        _ = try Subprocess.output(
            of: ["git", "-C", path, "update-index", "--add", "-z", "--index-info"],
            environment: Self.environment,
            input: Data(records)
        )
    }

    /// Stages `entries` and commits the index, dated `time` seconds after
    /// the epoch, and returns the commit's SHA.
    @discardableResult
    func commit(_ entries: [IndexEntry], _ message: String, at time: Int) throws -> String {
        try stage(entries)
        return try commitIndex(message, at: time)
    }
}
