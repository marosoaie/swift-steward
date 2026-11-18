import StewardTesting
import Testing

/// `FakeRepositoryFiles`' commits and line maps, which the diagnostics
/// rule reads for a source built at another commit.
@Suite("FakeRepositoryFiles' commits and line maps")
struct FakeRepositoryFilesLineMapTests {
    static let head = String(repeating: "ab", count: 20)
    static let base = String(repeating: "cd", count: 20)
    static let built = String(repeating: "ef", count: 20)

    /// The base put a line above a.swift's first.
    static let map = LineMap(diff: """
        diff --git a/a.swift b/a.swift
        index 1111111..2222222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -0,0 +1 @@
        +// From the base

        """)

    static let files = FakeRepositoryFiles(
        [head: ["a.swift": Array("let a = 1\n".utf8)], base: [:]],
        lineMaps: [built: map]
    )

    @Test("it knows a commit it holds files at, or a line map from")
    func commits() async throws {
        #expect(try await Self.files.commit(named: Self.head) == Self.head)
        #expect(try await Self.files.commit(named: Self.base) == Self.base)
        #expect(try await Self.files.commit(named: Self.built) == Self.built)
    }

    @Test("it knows a commit by its name exactly: not by a prefix, a ref, or another case", arguments: [
        String(head.prefix(7)), "HEAD", "main", "", head.uppercased(),
    ])
    func otherNames(name: String) async throws {
        #expect(try await Self.files.commit(named: name) == nil)
    }

    @Test("it maps the head to itself, a commit it holds a map from through that map, and no other")
    func lineMaps() async throws {
        #expect(try await Self.files.lineMap(from: Self.head, to: Self.head, attributesFrom: Self.base) == .identity)
        let map = try await Self.files.lineMap(from: Self.built, to: Self.head, attributesFrom: Self.base)
        #expect(map == Self.map)
        #expect(map.headLocation(ofLine: 1, inFile: "a.swift") == nil)
        #expect(map.headLocation(ofLine: 2, inFile: "a.swift") == Location(path: "a.swift", line: 1))
        let error = await #expect(throws: (any Error).self) {
            try await Self.files.lineMap(from: Self.base, to: Self.head, attributesFrom: Self.base)
        }
        #expect(error.map { "\($0)" } == """
            The reader has no map from the lines of \(Self.base) to those of \(Self.head).
            """)
    }
}
