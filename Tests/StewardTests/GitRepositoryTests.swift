import Foundation
@testable import Steward
import Testing

/// The git reader of files against git itself: what it reads is what
/// `git show <commit>:<path>` prints, byte for byte, and what isn't a
/// regular file within the limit is reported, not read.
@Suite("Reading files from a commit through git")
struct GitRepositoryTests {
    @Test("every regular file of a commit reads as git show prints it, one by one and all in one call")
    func everyFile() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let reader = Self.reader(of: fixture.repository)
        try await [fixture.base, fixture.head].asyncForEach { commit in
            let paths = try fixture.regularFiles(at: commit)
            #expect(paths.count >= 3)
            let expected = try paths.map { path in
                FileContents.bytes(try #require(try fixture.oracle.show(path, at: commit), "\(path)"))
            }
            #expect(try await reader.contents(ofFilesAt: paths, in: commit, limit: .max) == expected)
            try await zip(paths, expected).asyncForEach { path, contents in
                let read = try await reader.contents(ofFileAt: path, in: commit, limit: .max)
                #expect(read == contents, "\(path)")
            }
        }
        // Every name given, and the files whose bytes matter, were among them.
        let names = Set(try fixture.regularFiles(at: fixture.head).map { Array($0.utf8) })
        #expect(names.isSuperset(of: (FilesFixture.names + FilesFixture.contents.keys).map { Array($0.utf8) }))
    }

    @Test("a path is the file of that name, never a pattern", arguments: [
        "*.swift", "a?.swift", "[a]b.swift", "Sources/*", "Sources/**", ":(glob)**/*.swift", ":(icase)AB.swift",
        ":/Changed.swift", "AB.swift", "*.SWIFT",
    ])
    func patternsAreLiteral(pattern: String) async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        #expect(try fixture.oracle.show(pattern, at: fixture.head) == nil)
        #expect(try await Self.reader(of: fixture.repository).contents(
            ofFileAt: pattern, in: fixture.head, limit: .max
        ) == .noSuchFile)
    }

    @Test("a name and its canonical twin are two files, each read as its own, on macOS too", arguments: [
        ["caf\u{E9}.swift", "cafe\u{301}.swift"], ["q\u{37E}.swift", "q;.swift"],
    ])
    func unicodeSpellings(twins: [String]) async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        #expect(twins[0] == twins[1], "Swift's == compares canonical equivalence")
        #expect(Array(twins[0].utf8) != Array(twins[1].utf8))
        let expected = twins.map { FileContents.bytes(FilesFixture.defaultContents(of: $0)) }
        #expect(expected[0] != expected[1])
        try twins.forEach { name in
            let shown = try fixture.oracle.show(name, at: fixture.head)
            #expect(shown == FilesFixture.defaultContents(of: name))
        }
        let reader = Self.reader(of: fixture.repository)
        #expect(try await reader.contents(ofFilesAt: twins, in: fixture.head, limit: .max) == expected)
        #expect(try await reader.contents(ofFilesAt: twins.reversed(), in: fixture.head, limit: .max)
            == expected.reversed())
        try await zip(twins, expected).asyncForEach { name, contents in
            let read = try await reader.contents(ofFileAt: name, in: fixture.head, limit: .max)
            #expect(read == contents)
        }
    }

    @Test("a name that isn't UTF-8 can't be read under its decoded spelling, which names another file")
    func nonUTF8Name() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let decoded = String(decoding: FilesFixture.latin1Name, as: UTF8.self)
        #expect(decoded == "caf\u{FFFD}.swift")
        let read = try await Self.reader(of: fixture.repository)
            .contents(ofFileAt: decoded, in: fixture.head, limit: .max)
        #expect(read == .bytes(FilesFixture.defaultContents(of: decoded)))
        #expect(read == .bytes(try #require(try fixture.oracle.show(decoded, at: fixture.head))))
        // The Latin-1 file is there, under bytes no `String` holds.
        let listing = try fixture.oracle.output(["ls-tree", "-z", "--name-only", fixture.head])
        #expect(listing.split(separator: 0).contains { Array($0) == FilesFixture.latin1Name })
    }

    @Test("a symbolic link is reported, not followed, wherever it points", arguments: FilesFixture.links.keys.sorted())
    func symbolicLink(name: String) async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        #expect(try fixture.oracle.mode(of: name, at: fixture.head) == "120000")
        // What git show prints for a link is its target, never a file's bytes.
        #expect(try fixture.oracle.show(name, at: fixture.head) == Array((FilesFixture.links[name] ?? "").utf8))
        #expect(try await Self.reader(of: fixture.repository).contents(
            ofFileAt: name, in: fixture.head, limit: .max
        ) == .notRegularFile)
    }

    @Test("a file that becomes a symbolic link reads at the base and is reported at the head")
    func fileBecomesLink() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let reader = Self.reader(of: fixture.repository)
        let path = "link-later.swift"
        #expect(try await reader.contents(ofFileAt: path, in: fixture.base, limit: .max)
            == .bytes(try #require(try fixture.oracle.show(path, at: fixture.base))))
        #expect(try await reader.contents(ofFileAt: path, in: fixture.head, limit: .max) == .notRegularFile)
    }

    @Test("a submodule and a directory are reported, not read; a directory's path with a slash names nothing")
    func notRegularFiles() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let reader = Self.reader(of: fixture.repository)
        #expect(try fixture.oracle.mode(of: FilesFixture.submodule, at: fixture.head) == "160000")
        #expect(try fixture.oracle.mode(of: "Sources/App", at: fixture.head) == "040000")
        let read = try await reader.contents(
            ofFilesAt: [FilesFixture.submodule, "Vendor", "Sources", "Sources/App", "Sources/App/"],
            in: fixture.head,
            limit: .max
        )
        #expect(read == [.notRegularFile, .notRegularFile, .notRegularFile, .notRegularFile, .noSuchFile])
    }

    @Test("a file at the limit is read, one byte over is reported with its size, and an empty file reads as empty")
    func limits() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let reader = Self.reader(of: fixture.repository)
        let binary = try #require(FilesFixture.contents["binary.bin"])
        let size = try #require(Int(try fixture.oracle.text(["cat-file", "-s", "\(fixture.head):binary.bin"])))
        #expect(size == binary.count)

        #expect(try await reader.contents(ofFileAt: "binary.bin", in: fixture.head, limit: size) == .bytes(binary))
        #expect(try await reader.contents(ofFileAt: "binary.bin", in: fixture.head, limit: size - 1)
            == .tooLarge(size: size))
        #expect(try await reader.contents(ofFileAt: "empty.swift", in: fixture.head, limit: 0) == .bytes([]))
        #expect(try await reader.contents(ofFileAt: "script.sh", in: fixture.head, limit: 0) == .tooLarge(size: 9))
        #expect(try await reader.contents(ofFileAt: "empty.swift", in: fixture.head, limit: -1) == .tooLarge(size: 0))
        // The limit doesn't turn what isn't a regular file into one.
        #expect(try await reader.contents(ofFileAt: "link-passwd", in: fixture.head, limit: 0) == .notRegularFile)
    }

    @Test("a file is read from the commit asked for: deleted at the head, there at the base")
    func eachCommit() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let reader = Self.reader(of: fixture.repository)
        let paths = ["Changed.swift", "Deleted.swift", "ab.swift", "missing.swift"]
        try await [fixture.base, fixture.head].asyncForEach { commit in
            let expected = try paths.map { path in
                try fixture.oracle.show(path, at: commit).map(FileContents.bytes) ?? .noSuchFile
            }
            #expect(try await reader.contents(ofFilesAt: paths, in: commit, limit: .max) == expected)
        }
        #expect(try await reader.contents(ofFileAt: "Deleted.swift", in: fixture.head, limit: .max) == .noSuchFile)
        #expect(try await reader.contents(ofFileAt: "Changed.swift", in: fixture.base, limit: .max)
            == .bytes(Array("before\n".utf8)))
    }

    @Test("a path no file can have names no file, and doesn't stop the others being read", arguments: [
        "", "/", "/Changed.swift", "../Changed.swift", "./Changed.swift", "Sources/../Changed.swift",
        "Sources//App/Loader.swift", "Sources/App/Loader.swift/", "Sources/./App/Loader.swift", ".", "..",
        "Changed.swift\u{0}", "\u{0}", ".git", ".git/config",
    ])
    func impossiblePath(path: String) async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let read = try await Self.reader(of: fixture.repository).contents(
            ofFilesAt: [path, "Changed.swift"],
            in: fixture.head,
            limit: .max
        )
        #expect(read == [.noSuchFile, .bytes(Array("after\n".utf8))])
    }

    @Test("many files read in one call, split over several ls-tree calls, in the order asked, duplicates and all")
    func manyFiles() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let count = 120
        try (0..<count).forEach { try repository.write("file \($0)\n", to: "many/file-\($0).swift") }
        let commit = try repository.commit("Many files", at: PullRequestFixture.time)
        let paths = (0..<count).map { "many/file-\($0).swift" }.shuffled() + ["many/missing.swift", "many/file-7.swift"]
        // About 22 bytes a path: some twenty calls.
        #expect(GitRepository.calls(for: paths.map { Array($0.utf8) }, upTo: 128).count > 10)

        let read = try await Self.reader(of: repository).contents(
            ofFilesAt: paths,
            in: commit,
            limit: .max,
            pathBytesPerCall: 128
        )
        let oracle = GitOracle(directory: repository.path)
        let expected = try paths.map { try oracle.show($0, at: commit).map(FileContents.bytes) ?? .noSuchFile }
        #expect(read == expected)
        #expect(read.count { $0 == .noSuchFile } == 1)
        #expect(try await Self.reader(of: repository).contents(ofFilesAt: [], in: commit, limit: .max) == [])
    }

    @Test("seeded random paths never trap, and read only files git show also finds", arguments: 0..<4)
    func randomPaths(seed: UInt64) async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        var generator = SplitMix64(seed: seed)
        let pieces = "ab*?[]:/.\\-!^ \t\n\u{0}\u{E9}\u{301}\u{37E};\u{FFFD}".unicodeScalars.map(String.init)
            + ["Sources", "App", "Loader.swift"]
        let paths = (0..<200).map { _ in
            (0..<Int.random(in: 0...12, using: &generator)).map { _ in
                pieces.randomElement(using: &generator) ?? "a"
            }
            .joined()
        } + FilesFixture.names
        let read = try await Self.reader(of: fixture.repository)
            .contents(ofFilesAt: paths, in: fixture.head, limit: .max)
        #expect(read.count == paths.count)
        try zip(paths, read).forEach { path, contents in
            guard case .bytes(let bytes) = contents else { return }
            let shown = try fixture.oracle.show(path, at: fixture.head)
            #expect(shown == bytes, "\(path.debugDescription)")
        }
        #expect(Array(read.suffix(FilesFixture.names.count)) == FilesFixture.names.map {
            .bytes(FilesFixture.defaultContents(of: $0))
        })
    }

    static func reader(of repository: TestRepository) -> GitRepository {
        GitRepository(git: Git(
            directory: repository.path,
            environment: TestRepository.runEnvironment(adding: [:])
        ))
    }
}

/// SplitMix64: a seeded generator, so a random test's inputs are the same
/// on every run and every machine.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
