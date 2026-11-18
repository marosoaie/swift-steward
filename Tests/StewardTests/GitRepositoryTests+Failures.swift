import Foundation
@testable import Steward
import Testing

/// Reads that fail, as they must, rather than answer wrongly or crash.
extension GitRepositoryTests {
    @Test("a commit the repository lacks, or one spelled as an option, fails the read", arguments: [
        String(repeating: "0", count: 40), "--output=/dev/null", "-p", "", "HEAD:Changed.swift",
    ])
    func badCommit(commit: String) async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        await #expect(throws: ContextError.self) {
            try await Self.reader(of: fixture.repository).contents(ofFileAt: "Changed.swift", in: commit, limit: .max)
        }
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
        let reader = GitRepository(git: Git(
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
        // A read that doesn't need its size is untouched.
        #expect(try await reader.contents(ofFileAt: "Changed.swift", in: fixture.head, limit: .max)
            == .bytes(Array("after\n".utf8)))
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
        let reader = GitRepository(git: Git(
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
