import Foundation
import GitDiffKit
@testable import Steward
import StewardTesting
import Testing

/// `Rule.changedFiles`: which files it checks, what it gives the check,
/// what it skips and fails, and how it reads.
@Suite("Rule.changedFiles")
struct RuleChangedFilesTests {
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
        context.localRepository = FakeLocalRepository([context.git.head: [
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
        context.localRepository = CountingFiles(reads: reads, files: FakeLocalRepository([context.git.head: Dictionary(
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
        let reader: any LocalRepository = GitRepository(git: Git(
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
        context.localRepository = GitRepository(git: git)
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

    @Test("a link or a submodule git only renames, writing no mode, is skipped, and a regular file beside it read")
    func renamedLinks() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        try repository.write("struct Moved {}\n", to: "Sources/Moved.swift")
        try FileManager.default.createSymbolicLink(
            atPath: repository.url.appendingPathComponent("Sources/Link.swift").path,
            withDestinationPath: "Moved.swift"
        )
        let first = try repository.commit("Files", at: 0)
        try repository.git(["update-index", "--add", "--cacheinfo", "160000,\(first),Sources/Vendor"])
        let base = try repository.commitIndex("Submodule", at: 1)
        try repository.git(["mv", "Sources/Moved.swift", "Sources/Renamed.swift"])
        try repository.git(["mv", "Sources/Link.swift", "Sources/Linked.swift"])
        try repository.git(["rm", "--quiet", "--cached", "Sources/Vendor"])
        try repository.git(["update-index", "--add", "--cacheinfo", "160000,\(first),Sources/Vendored"])
        let head = try repository.commitIndex("Renames", at: 2)

        let git = Git(directory: repository.path, environment: TestRepository.runEnvironment(adding: [:]))
        var context = try Context.fixture(diff: "")
        context.git = try await GitChanges(base: base, head: head, git: git)
        context.localRepository = GitRepository(git: git)
        // What the case needs: three renames, none with a mode.
        let headers = context.git.diff.files.map(\.header)
        #expect(headers.count == 3)
        #expect(headers.allSatisfy { $0.oldPath != $0.newPath && $0.newMode == nil })
        let recording = RecordingConsole()
        let rule = Rule.changedFiles("Renamed", in: "Sources/**") { file in
            [.message(String(decoding: file.contents, as: UTF8.self), at: Location(path: file.path))]
        }
        let findings = try await rule.check(context, Log(mode: .dryRun, console: recording.console))
        #expect(findings == [.message("struct Moved {}\n", at: Location(path: "Sources/Renamed.swift"))])
        #expect(await recording.finish() == [
            .error("Renamed: skipped Sources/Linked.swift, not a regular file at the head\n"),
            .error("Renamed: skipped Sources/Vendored, not a regular file at the head\n"),
        ])
    }
}
