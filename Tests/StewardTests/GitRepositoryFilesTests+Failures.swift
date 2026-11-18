import Foundation
@testable import Steward
import Testing

/// Reads that fail, as they must, rather than answer wrongly or crash.
extension GitRepositoryFilesTests {
    @Test("a commit the repository lacks, or one spelled as an option, fails the read", arguments: [
        String(repeating: "0", count: 40), "--output=/dev/null", "-p", "", "HEAD:Changed.swift",
    ])
    func badCommit(commit: String) async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let error = await #expect(throws: ContextError.self) {
            try await Self.reader(of: fixture.repository).contents(ofFileAt: "Changed.swift", in: commit, limit: .max)
        }
        // git's own status is lost: xargs reports any failure as its own.
        #expect(error?.description.contains("the status is that of xargs -0") == true)
    }

    @Test("a tree isn't a commit, so reading from one fails")
    func treeIsNoCommit() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let tree = try fixture.oracle.text(["rev-parse", "\(fixture.head)^{tree}"])
        await #expect(throws: ContextError.self) {
            try await Self.reader(of: fixture.repository).contents(ofFileAt: "Changed.swift", in: tree, limit: .max)
        }
    }

    @Test("a path too long for any command line fails the read rather than crash")
    func overlongPath() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        await #expect(throws: ContextError.self) {
            try await Self.reader(of: fixture.repository).contents(
                ofFileAt: String(repeating: "a", count: 4 << 20),
                in: fixture.head,
                limit: .max
            )
        }
    }

    @Test("git's pathspec variables can't make paths match as globs, regardless of case, or stop git")
    func pathspecVariables() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let variables = [
            "GIT_GLOB_PATHSPECS": "1", "GIT_ICASE_PATHSPECS": "1", "GIT_NOGLOB_PATHSPECS": "1",
            "GIT_LITERAL_PATHSPECS": "0",
        ]
        let reader = GitRepositoryFiles(git: Git(
            directory: fixture.repository.path,
            environment: TestRepository.runEnvironment(adding: variables)
        ))
        let read = try await reader.contents(
            ofFilesAt: ["a*.swift", "AB.swift", "*.swift", "ab.swift"],
            in: fixture.head,
            limit: .max
        )
        #expect(read == [
            .bytes(FilesFixture.defaultContents(of: "a*.swift")), .noSuchFile, .noSuchFile,
            .bytes(FilesFixture.defaultContents(of: "ab.swift")),
        ])
    }

    @Test("a file whose blob the repository lacks fails the read, rather than read as something else")
    func missingBlob() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        // As in a partial clone that can't fetch it: `ls-tree --long`
        // says `BAD` for its size, and succeeds.
        let object = try fixture.oracle.text(["rev-parse", "\(fixture.head):ab.swift"])
        let objects = fixture.repository.url.appendingPathComponent(".git/objects", isDirectory: true)
        try FileManager.default.removeItem(
            at: objects.appendingPathComponent("\(object.prefix(2))/\(object.dropFirst(2))")
        )
        let listing = try fixture.oracle.text(["ls-tree", "--long", fixture.head, "--", "ab.swift"])
        #expect(listing.contains(" BAD\t"))
        let reader = Self.reader(of: fixture.repository)
        let error = await #expect(throws: ContextError.self) {
            try await reader.contents(ofFilesAt: ["Changed.swift", "ab.swift"], in: fixture.head, limit: .max)
        }
        #expect(error?.description.contains(object) == true)
        #expect(error?.description.hasPrefix("git ls-tree --long succeeded, but") == true)
        // A read that doesn't need its size is untouched.
        #expect(try await reader.contents(ofFileAt: "Changed.swift", in: fixture.head, limit: .max)
            == .bytes(Array("after\n".utf8)))
    }

    @Test("a tree naming one path twice, as different entries, fails reading that path, and only that one")
    func duplicateEntries() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let first = try repository.blob(Array("first\n".utf8))
        let second = try repository.blob(Array("second\n".utf8))
        // `git mktree` writes what it's given; `git fsck` would call the
        // tree damaged.
        let tree = String(decoding: try Subprocess.output(
            of: ["git", "-C", repository.path, "mktree"],
            environment: TestRepository.environment,
            input: Data("""
                100644 blob \(first)\tdup.swift
                100644 blob \(second)\tdup.swift
                100644 blob \(first)\tsame.swift
                100644 blob \(first)\tsame.swift

                """.utf8)
        ), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try repository.git(["commit-tree", tree, "-m", "Damaged"])
        let listing = try repository.git(["ls-tree", commit])
        #expect(listing.components(separatedBy: "\tdup.swift").count == 3)

        let reader = Self.reader(of: repository)
        let error = await #expect(throws: ContextError.self) {
            try await reader.contents(ofFilesAt: ["same.swift", "dup.swift"], in: commit, limit: .max)
        }
        #expect(error?.description.contains("dup.swift twice") == true)
        // The same entry twice names one file.
        #expect(try await reader.contents(ofFileAt: "same.swift", in: commit, limit: .max)
            == .bytes(Array("first\n".utf8)))
    }

    @Test("a directory listed again for a path inside it, in another call, is no duplicate")
    func directoryInTwoCalls() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let read = try await Self.reader(of: fixture.repository).contents(
            ofFilesAt: ["Sources/App", "Sources/App/Loader.swift"],
            in: fixture.head,
            limit: .max,
            pathBytesPerCall: 1
        )
        #expect(read == [.notRegularFile, .bytes(FilesFixture.defaultContents(of: "Sources/App/Loader.swift"))])
    }

    @Test("a read fails, naming the tool, when xargs or git isn't on PATH", arguments: ["xargs", "git"])
    func missingTool(tool: String) async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        // A PATH with the other tool alone.
        let tools = fixture.repository.root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try ["xargs", "git"].filter { $0 != tool }.forEach { other in
            let found = try Subprocess.output(of: ["sh", "-c", "command -v \(other)"])
            try FileManager.default.createSymbolicLink(
                atPath: tools.appendingPathComponent(other).path,
                withDestinationPath: String(decoding: found, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let reader = GitRepositoryFiles(git: Git(
            directory: fixture.repository.path,
            environment: TestRepository.runEnvironment(adding: ["PATH": tools.path])
        ))
        let error = await #expect(throws: ContextError.self) {
            try await reader.contents(ofFileAt: "Changed.swift", in: fixture.head, limit: .max)
        }
        guard case .gitUnavailable(let reason)? = error else {
            Issue.record("expected gitUnavailable, got \(String(describing: error))")
            return
        }
        #expect(reason.contains(tool))
        #expect(error?.description.contains("xargs -0") == true)
    }
}
