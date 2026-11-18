import Foundation
import GitDiffKit
@testable import Steward
import StewardTesting
import Testing

/// `Rule.changedFiles`: which files it checks, what it gives the check,
/// what it skips and fails, and how it reads.
@Suite("Rule.changedFiles")
struct RuleChangedFilesTests {
    /// Edits A.swift's second line, creates New.swift, deletes Old.swift,
    /// renames Moved.swift unchanged, edits a generated file and the
    /// README, adds a link, a submodule and a file of 43 bytes.
    static let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 1111111..2222222 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1,2 +1,2 @@
         import Steward
        -let a = 1
        +let a = 2
        diff --git a/Sources/New.swift b/Sources/New.swift
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/Sources/New.swift
        @@ -0,0 +1 @@
        +struct New {}
        diff --git a/Sources/Old.swift b/Sources/Old.swift
        deleted file mode 100644
        index 4444444..0000000
        --- a/Sources/Old.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -struct Old {}
        diff --git a/Old/Moved.swift b/Sources/Moved.swift
        similarity index 100%
        rename from Old/Moved.swift
        rename to Sources/Moved.swift
        diff --git a/Sources/Generated/G.swift b/Sources/Generated/G.swift
        index 5555555..6666666 100644
        --- a/Sources/Generated/G.swift
        +++ b/Sources/Generated/G.swift
        @@ -1 +1 @@
        -let g = 1
        +let g = 2
        diff --git a/README.md b/README.md
        index 7777777..8888888 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -# Old
        +# New
        diff --git a/Sources/Link.swift b/Sources/Link.swift
        new file mode 120000
        index 0000000..9999999
        --- /dev/null
        +++ b/Sources/Link.swift
        @@ -0,0 +1 @@
        +A.swift
        \\ No newline at end of file
        diff --git a/Sources/Vendor b/Sources/Vendor
        new file mode 160000
        index 0000000..1234567
        --- /dev/null
        +++ b/Sources/Vendor
        @@ -0,0 +1 @@
        +Subproject commit 1234567890123456789012345678901234567890
        diff --git a/Sources/Big.swift b/Sources/Big.swift
        new file mode 100644
        index 0000000..abcdef0
        --- /dev/null
        +++ b/Sources/Big.swift
        @@ -0,0 +1 @@
        +let big = "012345678901234567890123456789"

        """

    static let files = [
        "Sources/A.swift": "import Steward\nlet a = 2\n",
        "Sources/New.swift": "struct New {}\n",
        "Sources/Moved.swift": "struct Moved {}\n",
        "Sources/Generated/G.swift": "let g = 2\n",
        "README.md": "# New\n",
        "Sources/Big.swift": "let big = \"012345678901234567890123456789\"\n",
    ]

    /// A rule over `Sources/**` but `Sources/Generated/**`, at a limit of
    /// 40 bytes, whose check reports what it was given.
    static let described = Rule.changedFiles(
        "Described",
        in: "Sources/**",
        excluding: "Sources/Generated/**",
        limit: 40
    ) { [.message(describe($0), at: Location(path: $0.path))] }

    static func describe(_ file: ChangedFile) -> String {
        "\(String(decoding: file.contents, as: UTF8.self).debugDescription) \(file.changedLines.ranges)"
    }

    @Test("each file at the head that the pattern matches and the exclusion doesn't is checked, in diff order")
    func selection() async throws {
        let context = try Context.fixture(diff: Self.diff, files: Self.files)
        let recording = RecordingConsole()
        let findings = try await Self.described.check(context, Log(mode: .dryRun, console: recording.console))
        #expect(findings == [
            .message(#""import Steward\nlet a = 2\n" [ClosedRange(2...2)]"#, at: Location(path: "Sources/A.swift")),
            .message(#""struct New {}\n" [ClosedRange(1...1)]"#, at: Location(path: "Sources/New.swift")),
            .message(#""struct Moved {}\n" []"#, at: Location(path: "Sources/Moved.swift")),
        ])
        #expect(await recording.finish() == [
            .error("Described: skipped Sources/Link.swift, a symbolic link\n"),
            .error("Described: skipped Sources/Vendor, a submodule\n"),
            .error("Described: skipped Sources/Big.swift, 43 bytes, over the limit of 40\n"),
        ])
    }

    @Test("a file the diff lists at the head that the head doesn't have, or has as no regular file, fails")
    func unreadable() async throws {
        var context = try Context.fixture(diff: Self.diff)
        context.files = FakeRepositoryFiles([context.git.head: [
            "Sources/A.swift/inside": Array("a directory's file\n".utf8),
            "Sources/Moved.swift": Array("struct Moved {}\n".utf8),
        ]])
        let findings = try await Self.described.evaluate(context)
        #expect(findings.map(\.kind) == [.failure, .failure, .message, .failure])
        #expect(findings.map(\.location?.path) == [
            "Sources/A.swift", "Sources/New.swift", "Sources/Moved.swift", "Sources/Big.swift",
        ])
        #expect(findings[0].text.hasSuffix("the head has something else there."))
        #expect(findings[1].text.hasSuffix("the head has no such file."))
    }

    @Test("a name that isn't UTF-8 fails without a read, while the file its decoded name names is read as its own")
    func latin1Name() async throws {
        let diff = """
            diff --git "a/caf\\351.swift" "b/caf\\351.swift"
            new file mode 100644
            index 0000000..1111111
            --- /dev/null
            +++ "b/caf\\351.swift"
            @@ -0,0 +1 @@
            +Latin-1 name
            diff --git a/caf\u{FFFD}.swift b/caf\u{FFFD}.swift
            new file mode 100644
            index 0000000..2222222
            --- /dev/null
            +++ b/caf\u{FFFD}.swift
            @@ -0,0 +1 @@
            +replacement character

            """
        let context = try Context.fixture(diff: diff, files: ["caf\u{FFFD}.swift": "replacement character\n"])
        let findings = try await Rule.changedFiles("Any", in: "**") { file in
            [.message(Self.describe(file), at: Location(path: file.path))]
        }.evaluate(context)
        #expect(findings == [
            .failure(#"""
                Couldn't check `caf\351.swift`: its name isn't UTF-8, so no `String` names it, and read by its \#
                name decoded, it could be another file.
                """#),
            .message(#""replacement character\n" [ClosedRange(1...1)]"#, at: Location(path: "caf\u{FFFD}.swift")),
        ])
    }

    @Test("files are read in batches of 64 MiB at the limit per file, through the reader's batch read", arguments: [
        (FileContents.defaultLimit, [5]), (32 << 20, [2, 2, 1]), (Int.max, [1, 1, 1, 1, 1]), (0, [5]),
    ])
    func batches(limit: Int, batches: [Int]) async throws {
        let diff = (1...5).map { number in
            """
            diff --git a/F\(number).swift b/F\(number).swift
            new file mode 100644
            index 0000000..1111111
            --- /dev/null
            +++ b/F\(number).swift
            @@ -0,0 +1 @@
            +let f = \(number)

            """
        }.joined()
        var context = try Context.fixture(diff: diff)
        let reads = Reads()
        context.files = CountingFiles(reads: reads, files: FakeRepositoryFiles([context.git.head: Dictionary(
            uniqueKeysWithValues: (1...5).map { ("F\($0).swift", Array("let f = \($0)\n".utf8)) }
        )]))
        let findings = try await Rule.changedFiles("Any", in: "*.swift", limit: limit) { file in
            [.message(String(decoding: file.contents, as: UTF8.self), at: Location(path: file.path))]
        }.evaluate(context)
        #expect(await reads.batches == batches)
        #expect(await reads.singles == 0)
        #expect(findings.count == (limit == 0 ? 0 : 5))
    }

    @Test("the git reader's batch read is the protocol's: two git processes for any number of paths")
    func gitBatch() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let trace = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trace) }
        let reader: any RepositoryFiles = GitRepositoryFiles(git: Git(
            directory: fixture.repository.path,
            environment: TestRepository.runEnvironment(adding: ["GIT_TRACE": trace.path])
        ))
        let paths = FilesFixture.names + FilesFixture.contents.keys.sorted()
        let read = try await reader.contents(ofFilesAt: paths, in: fixture.head, limit: .max)
        #expect(read.count == paths.count)
        #expect(!read.contains(.noSuchFile))
        let commands = try String(contentsOf: trace, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.contains("trace: built-in: git ") }
        #expect(commands.count == 2, "\(commands)")
    }

    @Test("on a real repository, each changed file reads its own bytes, by names of every kind")
    func realRepository() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let git = Git(directory: fixture.repository.path, environment: TestRepository.runEnvironment(adding: [:]))
        var context = try Context.fixture(diff: "")
        context.git = try await GitChanges(base: fixture.base, head: fixture.head, git: git)
        context.files = GitRepositoryFiles(git: git)
        let recording = RecordingConsole()
        let rule = Rule.changedFiles("Any", in: "**") { file in
            [.message(String(decoding: file.contents, as: UTF8.self), at: Location(path: file.path))]
        }
        let findings = try await rule.check(context, Log(mode: .dryRun, console: recording.console))
        let read = Dictionary(findings.compactMap { finding in
            finding.location.map { ($0.path.unicodeScalars.map(\.value), finding.text) }
        }) { first, _ in first }
        let expected = FilesFixture.names.map { ($0, FilesFixture.defaultContents(of: $0)) }
            + FilesFixture.contents.map { ($0.key, $0.value) }
            + [("Changed.swift", Array("after\n".utf8)), ("script.sh", Array("echo run\n".utf8))]
        #expect(read.count == expected.count)
        expected.forEach { path, contents in
            #expect(read[path.unicodeScalars.map(\.value)] == String(decoding: contents, as: UTF8.self), "\(path)")
        }
        #expect(findings.filter { $0.kind == .failure }.map(\.text) == [#"""
            Couldn't check `caf\351.swift`: its name isn't UTF-8, so no `String` names it, and read by its name \#
            decoded, it could be another file.
            """#])
        let logged = await recording.finish()
        #expect(logged.count == FilesFixture.links.count + 1)
        #expect(logged.contains(.error("Any: skipped \(FilesFixture.submodule), a submodule\n")))
    }

    /// The reads a `CountingFiles` was asked for: each batch's size, and
    /// how many single reads.
    actor Reads {
        var batches: [Int] = []
        var singles = 0

        func record(batch size: Int) {
            batches.append(size)
        }

        func recordSingle() {
            singles += 1
        }
    }

    /// A reader that counts its reads, then reads through another, whose
    /// batch read is the protocol's default.
    struct CountingFiles: RepositoryFiles {
        let reads: Reads
        let files: FakeRepositoryFiles

        func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
            await reads.recordSingle()
            return try await files.contents(ofFileAt: path, in: commit, limit: limit)
        }

        func contents(ofFilesAt paths: [String], in commit: String, limit: Int) async throws -> [FileContents] {
            await reads.record(batch: paths.count)
            return try await files.contents(ofFilesAt: paths, in: commit, limit: limit)
        }
    }
}
