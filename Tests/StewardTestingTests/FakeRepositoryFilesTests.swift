import StewardTesting
import Testing

/// The in-memory repository a fixture reads: the git reader's answers for
/// the paths it holds.
@Suite("FakeRepositoryFiles")
struct FakeRepositoryFilesTests {
    static let head = String(repeating: "4e", count: 20)
    static let base = String(repeating: "ba", count: 20)

    static let files = FakeRepositoryFiles([
        head: [
            "Sources/App/Loader.swift": Array("struct Loader {}\n".utf8),
            "README.md": Array("# App\n".utf8),
            "empty": [],
            "caf\u{E9}.swift": Array("precomposed\n".utf8),
        ],
        base: ["README.md": Array("# Old\n".utf8)],
    ])

    @Test("a file reads at its own commit, and nowhere else")
    func commits() async throws {
        #expect(try await Self.files.contents(ofFileAt: "README.md", in: Self.head, limit: .max)
            == .bytes(Array("# App\n".utf8)))
        #expect(try await Self.files.contents(ofFileAt: "README.md", in: Self.base, limit: .max)
            == .bytes(Array("# Old\n".utf8)))
        #expect(try await Self.files.contents(ofFileAt: "empty", in: Self.head, limit: 0) == .bytes([]))
        #expect(try await Self.files.contents(ofFileAt: "empty", in: Self.base, limit: .max) == .noSuchFile)
        let unknown = String(repeating: "0", count: 40)
        #expect(try await Self.files.contents(ofFileAt: "README.md", in: unknown, limit: .max) == .noSuchFile)
    }

    @Test("a path names one file byte for byte, and a path with files under it is a directory", arguments: [
        ("Sources/App/Loader.swift", "file"), ("Sources", "directory"), ("Sources/App", "directory"),
        ("Sources/", "none"), ("./README.md", "none"), ("README.md/", "none"), ("readme.md", "none"),
        ("Sources/App/Loader", "none"), ("", "none"), ("/README.md", "none"),
        ("caf\u{E9}.swift", "file"), ("cafe\u{301}.swift", "none"),
    ])
    func paths(path: String, kind: String) async throws {
        let read = try await Self.files.contents(ofFileAt: path, in: Self.head, limit: .max)
        switch kind {
        case "file": #expect(read != .noSuchFile && read != .notRegularFile)
        case "directory": #expect(read == .notRegularFile)
        default: #expect(read == .noSuchFile)
        }
    }

    @Test("a file over the limit is reported by its size, and one at the limit is read", arguments: [
        (17, true), (18, true), (16, false), (0, false), (-1, false),
    ])
    func limits(limit: Int, isRead: Bool) async throws {
        let read = try await Self.files.contents(ofFileAt: "Sources/App/Loader.swift", in: Self.head, limit: limit)
        #expect(read == (isRead ? .bytes(Array("struct Loader {}\n".utf8)) : .tooLarge(size: 17)))
    }
}
