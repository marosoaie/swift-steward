import Foundation
@testable import Steward
import StewardTesting
import Testing

/// StewardTesting's in-memory repository against the git reader: given a
/// commit's regular files, it answers every path of that commit as the
/// git reader does, at every limit, and paths the commit doesn't have too.
@Suite("FakeLocalRepository against the git reader")
struct FakeLocalRepositoryOracleTests {
    @Test("on a repository of every kind of entry and hostile names, it answers as the git reader")
    func filesFixture() async throws {
        let fixture = try FilesFixture()
        defer { fixture.remove() }
        let reader = GitRepositoryTests.reader(of: fixture.repository)
        try await Self.expectSameAnswers(of: reader, in: fixture.oracle, at: fixture.base)
        try await Self.expectSameAnswers(of: reader, in: fixture.oracle, at: fixture.head)
    }

    @Test(
        "on a real repository, it answers as the git reader",
        .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
    )
    func realRepository() async throws {
        let head = try EventPayload.pullRequest("git-diff-parser-8").sha(of: "head")
        let mirror = try RepositoryMirror.local("git-diff-parser", having: [head])
        let reader = GitRepository(git: Git(directory: mirror.path))
        try await Self.expectSameAnswers(of: reader, in: GitOracle(directory: mirror.path), at: head)
    }

    /// Expects a `FakeLocalRepository` of `commit`'s regular files to
    /// answer as `reader` for each regular file and each directory with
    /// one under it, and for paths that name nothing, at three limits.
    ///
    /// The fake holds no symbolic links or submodules, and says so in its
    /// documentation: for those, and for a directory holding only those,
    /// it answers `.noSuchFile` where git says `.notRegularFile`.
    private static func expectSameAnswers(
        of reader: GitRepository,
        in oracle: GitOracle,
        at commit: String
    ) async throws {
        let modes = try oracle.modes(at: commit)
        let regular = modes.filter { $0.value.hasPrefix("100") }.keys.sorted()
        let read = try await reader.contents(ofFilesAt: regular, in: commit, limit: .max)
        let files = Dictionary(uniqueKeysWithValues: zip(regular, read).compactMap { pair -> (String, [UInt8])? in
            guard case .bytes(let bytes) = pair.1 else { return nil }
            return (pair.0, bytes)
        })
        #expect(files.count == regular.count, "every regular file reads")
        let fake = FakeLocalRepository([commit: files])

        let directories = modes.filter { $0.value == "040000" }.keys.sorted().filter { directory in
            regular.contains { $0.utf8.starts(with: Array(directory.utf8) + [UInt8(ascii: "/")]) }
        }
        let someFile = try #require(regular.first)
        let missing = ([
            "", "/", ".", "Missing.swift", "\(someFile)/", "./\(someFile)", "/\(someFile)", "\(someFile).swift",
            String(someFile.dropLast()), someFile.uppercased(), someFile.lowercased(),
        ] + directories.prefix(1).flatMap { ["\($0)/", "\($0)/Missing.swift"] }).filter { modes[$0] == nil }

        let sizes = files.values.map(\.count).sorted()
        try #require(!sizes.isEmpty)
        let middle = sizes[sizes.count / 2]
        let paths = regular + directories + missing
        try await [Int.max, middle, 0].asyncForEach { limit in
            let expected = try await reader.contents(ofFilesAt: paths, in: commit, limit: limit)
            #expect(expected.contains { if case .tooLarge = $0 { true } else { false } } == (limit < sizes.last ?? 0))
            try await zip(paths, expected).asyncForEach { path, answer in
                let read = try await fake.contents(ofFileAt: path, in: commit, limit: limit)
                #expect(read == answer, "\(path)")
            }
        }
    }
}
