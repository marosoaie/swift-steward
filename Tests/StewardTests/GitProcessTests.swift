import Foundation
@testable import Steward
import Testing

/// Steward's git runner as a launcher of processes: what each run leaves
/// behind in the process that runs a Dangerfile.
@Suite("Running git")
struct GitProcessTests {
    static let rounds = 25
    /// Launches at once: macOS gives a process 256 descriptors by default,
    /// and each launch holds six until git exits.
    static let width = 16

    /// swift-corelibs-foundation never frees a `Process` that nothing waits
    /// for, so on Linux every run kept its pipes open. At about 1,360 open
    /// descriptors, `Process.run()` itself crashes reading `/proc/self/fd`.
    @Test("git run hundreds of times, many at once, leaves no file descriptor open")
    func descriptors() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }
        let git = Git(directory: repository.path, environment: TestRepository.runEnvironment(adding: [:]))
        let before = try Self.openDescriptors()
        // Imperative: rounds, so no more than `width` launches hold
        // descriptors at once.
        for _ in 0..<Self.rounds {
            try await withThrowingTaskGroup(of: Void.self) { group in
                (0..<Self.width).forEach { _ in
                    group.addTask { _ = try await git.output(["rev-parse", "--git-dir"]) }
                }
                try await group.waitForAll()
            }
        }
        let after = try Self.openDescriptors()
        // Other suites open files meanwhile, so some slack; a leak of even
        // one descriptor a run is hundreds.
        #expect(after - before < Self.rounds * Self.width / 4)
    }

    @Test("git's input is read from a file that's gone by the time git starts, or that's never left behind")
    func inputFile() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-input-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let input = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let handle = try Git.handle(reading: input, in: parent)
        defer { try? handle.close() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        #expect(try handle.readToEnd() == Data(input))

        let missing = parent.appendingPathComponent("missing", isDirectory: true)
        #expect(throws: ContextError.self) {
            try Git.handle(reading: input, in: missing)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    /// The descriptors the test process has open, as the kernel lists them.
    static func openDescriptors() throws -> Int {
        #if os(Linux)
        try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
        #else
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        #endif
    }
}
