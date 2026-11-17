import Foundation
@testable import Steward

/// A repository whose two commits hold every kind of entry a reader of
/// files must tell apart, under names that may hold any byte but NUL:
/// built through the index, so the file system never sees them.
///
/// The base commit has `Changed.swift`, `Deleted.swift`, and
/// `link-later.swift`. The head commit, on top of it, changes the first,
/// deletes the second, turns the third into a symbolic link, and adds
/// regular files under `names` and `contents`, a file whose name isn't
/// UTF-8, symbolic links, a submodule, and directories.
struct FilesFixture {
    let repository: TestRepository
    let base: String
    let head: String

    var oracle: GitOracle { GitOracle(directory: repository.path) }

    /// Names of regular files at the head, each holding
    /// `defaultContents(of:)`: spaces, line breaks, glob and pathspec
    /// syntax, a leading dash, and a name in its precomposed and its
    /// decomposed spelling, which Swift's `==` takes for one.
    static let names = [
        "Sources/App/Loader.swift", "with space.swift", "tab\t.swift", "new\nline.swift", "trailing space ",
        "a*.swift", "ab.swift", "[ab].swift", "?.swift", "*", ":(glob)*.swift", ":/top.swift",
        "-dash.swift", "back\\slash.swift", "quote\".swift", ".hidden",
        "caf\u{E9}.swift", "cafe\u{301}.swift", "caf\u{FFFD}.swift", "\u{65E5}\u{672C}.swift",
    ]

    /// Regular files at the head whose contents test the reader's bytes.
    static let contents: [String: [UInt8]] = [
        "empty.swift": [],
        "binary.bin": Array(repeating: (0...255).map(UInt8.init), count: 4).flatMap(\.self),
        "crlf.txt": Array("one\r\ntwo\r\n".utf8),
        "no-newline.txt": Array("last".utf8),
        "latin1.txt": [0x63, 0x61, 0x66, 0xE9, 0x0A, 0xFF, 0xFE, 0x00, 0x80],
    ]

    /// A name that isn't UTF-8: `caf`, the Latin-1 byte for `é`, `.swift`.
    /// Decoded, it's `caf\u{FFFD}.swift`, the name of another file.
    static let latin1Name: [UInt8] = Array("caf".utf8) + [0xE9] + Array(".swift".utf8)

    /// Symbolic links at the head, and their targets.
    static let links = [
        "link-inside": "Changed.swift",
        "link-passwd": "/etc/passwd",
        "link-outside": "../../outside.txt",
        "link-directory": "Sources",
        "link-later.swift": "Changed.swift",
    ]

    static let submodule = "Vendor/Library"

    /// Whether the reader can find a file stored under `name` where the
    /// tests run: on macOS, `Process` decomposes an argument's accented
    /// letters and git composes them back, so a name stored decomposed is
    /// out of its reach there.
    static func isReachable(_ name: String) -> Bool {
        #if canImport(Darwin)
        Array(name.utf8) == Array(name.precomposedStringWithCanonicalMapping.utf8)
        #else
        true
        #endif
    }

    /// What the reader gives for a file stored under `name` holding
    /// `bytes`.
    static func read(_ name: String, holding bytes: [UInt8]) -> FileContents {
        isReachable(name) ? .bytes(bytes) : .noSuchFile
    }

    static func defaultContents(of name: String) -> [UInt8] {
        Array("contents of \(name)\n".utf8)
    }

    init() throws {
        let repository = try TestRepository()
        self.repository = repository
        base = try repository.commit(
            [
                .file("Changed.swift", Array("before\n".utf8), in: repository),
                .file("Deleted.swift", Array("deleted\n".utf8), in: repository),
                .file("link-later.swift", Array("a file at first\n".utf8), in: repository),
            ],
            "Start",
            at: PullRequestFixture.time
        )
        let files = try Self.names.map {
            try TestRepository.IndexEntry.file($0, Self.defaultContents(of: $0), in: repository)
        }
            + Self.contents.map { try TestRepository.IndexEntry.file($0.key, $0.value, in: repository) }
            + [
                .file("script.sh", Array("echo run\n".utf8), executable: true, in: repository),
                .file(Self.latin1Name, Array("Latin-1 name\n".utf8), in: repository),
                .file("Changed.swift", Array("after\n".utf8), in: repository),
            ]
        let others = try [.removal("Deleted.swift")]
            + Self.links.map { try TestRepository.IndexEntry.link($0.key, to: $0.value, in: repository) }
            + [.submodule(Self.submodule, at: String(repeating: "1234567890", count: 4))]
        head = try repository.commit(files + others, "Change", at: PullRequestFixture.time + 60)
    }

    func remove() {
        repository.remove()
    }

    /// The regular files of `commit`, as `git ls-tree -r` lists them, with
    /// UTF-8 names: a `String` can't name any other.
    func regularFiles(at commit: String) throws -> [String] {
        try oracle.output(["ls-tree", "-r", "-z", "--full-tree", commit])
            .split(separator: 0)
            .compactMap { record -> String? in
                guard record.starts(with: Array("100".utf8)), let tab = record.firstIndex(of: UInt8(ascii: "\t"))
                else { return nil }
                return String(validating: record[record.index(after: tab)...], as: UTF8.self)
            }
    }
}
