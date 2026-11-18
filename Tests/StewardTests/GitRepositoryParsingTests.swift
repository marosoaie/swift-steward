@testable import Steward
import Testing

/// What the git reader makes of `ls-tree` and `cat-file` output, and of
/// the paths and numbers it's given: damaged output is refused or
/// skipped, never trusted, and nothing traps.
@Suite("Parsing what git prints for the file reader")
struct GitRepositoryParsingTests {
    typealias TreeEntry = GitRepository.TreeEntry

    static let first = String(repeating: "a1", count: 20)
    static let second = String(repeating: "b2", count: 20)
    static let third = String(repeating: "c3", count: 32)

    static func record(_ text: String) -> ArraySlice<UInt8> {
        ArraySlice(text.utf8)
    }

    @Test("a tree record gives its mode, type, object, size, and the path after its first tab, byte for byte")
    func treeRecord() throws {
        let file = try #require(TreeEntry(record: Self.record("100644 blob \(Self.first)     12\tdir/a\tb\nc.swift")))
        #expect(file.mode == "100644")
        #expect(file.type == "blob")
        #expect(file.object == Self.first)
        #expect(file.size == 12)
        #expect(file.path == Array("dir/a\tb\nc.swift".utf8))
        #expect(file.isRegularFile)
        let executable = try #require(TreeEntry(record: Self.record("100755 blob \(Self.third) 0\tscript.sh")))
        #expect(executable.isRegularFile)
        #expect(executable.size == 0)
        let missing = try #require(TreeEntry(record: Self.record("100644 blob \(Self.first)     BAD\tgone.swift")))
        #expect(missing.isRegularFile)
        #expect(missing.size == nil)
        #expect(executable.object.count == 64)
        let latin1 = try #require(TreeEntry(record: ArraySlice(Array("100644 blob \(Self.first) 1\t".utf8) + [0xE9])))
        #expect(latin1.path == [0xE9])
    }

    @Test("a link, a submodule, or a directory isn't a regular file, whatever its size", arguments: [
        "120000 blob \(first) 13\tlink", "160000 commit \(first) -\tVendor", "040000 tree \(first) -\tSources",
        "100644 tree \(first) 12\todd", "100644 commit \(first) -\todd",
    ])
    func notRegular(record: String) throws {
        let entry = try #require(TreeEntry(record: Self.record(record)))
        #expect(!entry.isRegularFile)
    }

    @Test("a size that isn't a number, or doesn't fit, is no size", arguments: [
        "100644 blob \(first) -\tno-size", "100644 blob \(first) BAD\tmissing",
        "100644 blob \(first) 99999999999999999999\toverflow",
    ])
    func noSize(record: String) throws {
        let entry = try #require(TreeEntry(record: Self.record(record)))
        #expect(entry.isRegularFile)
        #expect(entry.size == nil)
    }

    @Test("a record ls-tree doesn't write is refused", arguments: [
        "", "\t", "100644 blob \(first) 12", "100644 blob \(first)\tpath", "100644 blob \(first) 12 extra\tpath",
        "100644 blob \(first.uppercased()) 12\tpath", "100644 blob \(first.dropLast()) 12\tpath",
        "100644 blob \(first)0 12\tpath", "100644 blob \(String(repeating: "g", count: 40)) 12\tpath",
        "100644\tblob \(first) 12\tpath",
    ])
    func refusedRecord(record: String) {
        #expect(TreeEntry(record: Self.record(record)) == nil)
    }

    @Test("ls-tree output keeps its whole records and skips damaged ones")
    func treeOutput() {
        let output = Array("""
            100644 blob \(Self.first)       5\tone\u{0}garbage\u{0}\u{0}\
            040000 tree \(Self.second)       -\ttwo\u{0}100644 blob \(Self.second) 5
            """.utf8)
        #expect(TreeEntry.entries(in: output).map(\.path) == [Array("one".utf8), Array("two".utf8)])
        #expect(TreeEntry.entries(in: []).isEmpty)
    }

    /// An object as `cat-file --batch` prints it.
    struct Object {
        var id: String
        var type = "blob"
        var bytes: [UInt8]

        var printed: [UInt8] {
            Array("\(id) \(type) \(bytes.count)\n".utf8) + bytes + [UInt8(ascii: "\n")]
        }
    }

    static let objects = [
        Object(id: first, bytes: Array("line\n\(second) blob 3\nabc\n".utf8)),
        Object(id: second, bytes: []),
        Object(id: third, bytes: [0, 0xFF, UInt8(ascii: "\n"), 0x80]),
    ]

    static var printed: [UInt8] {
        objects.flatMap(\.printed)
    }

    @Test("cat-file's output gives each object asked for, even contents that look like headers")
    func batchOutput() throws {
        let parsed = try #require(GitRepository.batch(Self.printed, of: Self.objects.map(\.id)))
        #expect(parsed.count == 3)
        Self.objects.forEach { object in
            #expect(parsed[object.id] == GitRepository.BatchObject(type: object.type, bytes: object.bytes))
        }
        #expect(GitRepository.batch([], of: []) == [:])
    }

    /// Output `cat-file --batch` wouldn't print for the objects asked for.
    static let damagedBatches: [String: (output: [UInt8], objects: [String])] = [
        "a missing object": (Array("\(first) missing\n".utf8), [first]),
        "another object": (objects[1].printed, [first]),
        "objects out of order": (printed, objects.map(\.id).reversed()),
        "a size past the end": (Array("\(first) blob 6\nabc\n".utf8), [first]),
        "an overflowing size": (Array("\(first) blob 99999999999999999999\nabc\n".utf8), [first]),
        "a negative size": (Array("\(first) blob -1\nabc\n".utf8), [first]),
        "no line break after the contents": (Array("\(first) blob 3\nabcd".utf8), [first]),
        "bytes after the last object": (printed + [UInt8(ascii: "\n")], objects.map(\.id)),
        "a header too short": (Array("\(first) 3\nabc\n".utf8), [first]),
        "a header too long": (Array("\(first) blob 3 x\nabc\n".utf8), [first]),
        "nothing at all": ([], [first]),
        "output for no objects": (printed, []),
    ]

    @Test("cat-file output that isn't the objects asked for, in turn and in full, is refused",
          arguments: damagedBatches.keys.sorted())
    func refusedBatch(damage: String) throws {
        let damaged = try #require(Self.damagedBatches[damage])
        #expect(GitRepository.batch(damaged.output, of: damaged.objects) == nil)
    }

    @Test("every cut of cat-file's output short of its end is refused")
    func truncatedBatch() {
        let ids = Self.objects.map(\.id)
        let valid = Self.printed
        #expect((0..<valid.count).allSatisfy { GitRepository.batch(Array(valid.prefix($0)), of: ids) == nil })
    }

    @Test("seeded noise in git's output never traps, and a batch that parses has every object asked for",
          arguments: 0..<8)
    func noise(seed: UInt64) {
        var generator = SplitMix64(seed: seed)
        let ids = Self.objects.map(\.id)
        let valid = Self.printed
        let tree = Array("100644 blob \(Self.first)  12\tdir/a.swift\u{0}160000 commit \(Self.second) -\tVendor".utf8)
        let alphabet = Array("0123456789 \t\n-abcdef".utf8) + [0, 0xFF]
        (0..<500).forEach { _ in
            let damagedBatch = Self.mutate(valid, alphabet: alphabet, using: &generator)
            if let parsed = GitRepository.batch(damagedBatch, of: ids) {
                #expect(Set(parsed.keys) == Set(ids))
            }
            let damagedTree = Self.mutate(tree, alphabet: alphabet, using: &generator)
            TreeEntry.entries(in: damagedTree).forEach { entry in
                #expect(entry.object.count == 40 || entry.object.count == 64)
                #expect(entry.size.map { $0 >= 0 } ?? true)
            }
        }
    }

    /// `bytes` with a few bytes replaced, removed, or inserted.
    static func mutate(
        _ bytes: [UInt8],
        alphabet: [UInt8],
        using generator: inout SplitMix64
    ) -> [UInt8] {
        (0..<Int.random(in: 1...4, using: &generator)).reduce(into: bytes) { bytes, _ in
            let index = Int.random(in: 0...bytes.count, using: &generator)
            let byte = alphabet.randomElement(using: &generator) ?? 0
            switch Int.random(in: 0..<3, using: &generator) {
            case 0 where index < bytes.count: bytes[index] = byte
            case 1 where index < bytes.count: bytes.remove(at: index)
            default: bytes.insert(byte, at: index)
            }
        }
    }

    @Test("paths are split into calls within the budget, in order, and a longer path has a call of its own")
    func calls() {
        let paths = ["a", "bb", "ccc", String(repeating: "d", count: 20), "e", "ff"].map { Array($0.utf8) }
        // Each path counts its length and a separator: 2 + 3 + 4 fill 9.
        let calls = GitRepository.calls(for: paths, upTo: 9)
        #expect(calls.map { $0.map { String(decoding: $0, as: UTF8.self) } } == [
            ["a", "bb", "ccc"], [String(repeating: "d", count: 20)], ["e", "ff"],
        ])
        #expect(calls.flatMap(\.self) == paths)
        #expect(GitRepository.calls(for: [], upTo: 9).isEmpty)
        #expect(GitRepository.calls(for: paths, upTo: .max) == [paths])
        // No budget, or a nonsensical one, still gives every path a call.
        [0, -1, .min].forEach { budget in
            #expect(GitRepository.calls(for: paths, upTo: budget) == paths.map { [$0] })
        }
    }

    @Test("a path names a tree entry only when every component is a name", arguments: [
        ("a", true), ("a/b/c.swift", true), (".hidden", true), ("..a", true), ("a..", true), ("...", true),
        ("a/.b", true), ("with space/ x ", true), ("new\nline", true), ("", false), ("/", false), ("/a", false),
        ("a/", false), ("a//b", false), (".", false), ("..", false), ("./a", false), ("a/./b", false),
        ("a/..", false), ("../a", false), ("a\u{0}b", false), ("\u{0}", false),
    ])
    func treePath(path: String, isValid: Bool) {
        #expect(GitRepository.treePath(path) == (isValid ? Array(path.utf8) : nil))
    }

    @Test("a decimal is all ASCII digits and fits in an Int", arguments: [
        ("0", 0), ("007", 7), ("1048576", 1 << 20), ("9223372036854775807", Int.max),
        ("9223372036854775808", nil), ("99999999999999999999999", nil), ("", nil), ("-1", nil), ("+1", nil),
        (" 1", nil), ("1 ", nil), ("1a", nil), ("\u{661}", nil), ("\u{FF11}", nil),
    ] as [(String, Int?)])
    func decimal(text: String, value: Int?) {
        #expect(GitRepository.decimal(Array(text.utf8)) == value)
    }
}
