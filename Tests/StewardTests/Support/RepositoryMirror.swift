import Foundation
import Synchronization

/// Bare mirrors of this project's repositories on GitHub, cloned once into
/// the fixture cache the other test targets use, and fetched again only
/// when a commit a test needs is missing.
///
/// A mirror has every ref, `refs/pull/*` included, so it holds the head of
/// every pull request, merged or not. Tests only read it; one that writes
/// clones it first.
enum RepositoryMirror {
    static let directory = cacheRoot.appendingPathComponent("git-diff-parser-tests/repositories", isDirectory: true)

    /// As `RealWorldFixtureStore` in SwiftStewardTests resolves it: the
    /// user's caches folder on macOS, `$XDG_CACHE_HOME` or `~/.cache`
    /// elsewhere.
    private static var cacheRoot: URL {
        #if canImport(Darwin)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let environment = ProcessInfo.processInfo.environment
        let configured = [environment["XDG_CACHE_HOME"], environment["HOME"].map { "\($0)/.cache" }]
            .compactMap { $0 }
            .first { $0.hasPrefix("/") }
        return URL(
            fileURLWithPath: configured ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.cache",
            isDirectory: true
        )
        #endif
    }

    /// Held while a mirror is checked, cloned, or fetched: suites run in
    /// parallel, `.serialized` only orders the tests inside one, and two
    /// fetches into one mirror can fail on each other's ref locks.
    private static let refreshing = Mutex(())

    /// The mirror of `marosoaie/<name>`, cloned or fetched so that it has
    /// every commit in `commits`.
    static func local(_ name: String, having commits: [String]) throws -> URL {
        try refreshing.withLock { _ in
            let mirror = directory.appendingPathComponent("\(name).git", isDirectory: true)
            if !FileManager.default.fileExists(atPath: mirror.path) {
                try clone(name, to: mirror)
            }
            if try !missing(commits, in: mirror).isEmpty {
                _ = try Subprocess.output(
                    of: ["git", "-C", mirror.path, "fetch", "--quiet", "--prune", "origin"],
                    environment: TestRepository.environment
                )
            }
            let stillMissing = try missing(commits, in: mirror)
            guard stillMissing.isEmpty else {
                throw FixtureError("""
                    \(mirror.path) lacks \(stillMissing.joined(separator: ", ")) even after a fetch from \
                    github.com/marosoaie/\(name); delete the folder to clone it again
                    """)
            }
            return mirror
        }
    }

    /// Clones into a temporary folder beside `mirror`, then moves it into
    /// place, so an interrupted clone never looks like a mirror.
    private static func clone(_ name: String, to mirror: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).git", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: partial) }
        _ = try Subprocess.output(
            of: ["git", "clone", "--quiet", "--mirror", "https://github.com/marosoaie/\(name).git", partial.path],
            environment: TestRepository.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
        )
        // Another run may have finished its clone first; either is fine.
        try? FileManager.default.moveItem(at: partial, to: mirror)
    }

    private static func missing(_ commits: [String], in mirror: URL) throws -> [String] {
        try commits.filter { commit in
            let output = try Subprocess.output(
                of: ["sh", "-c", "git -C \"$0\" cat-file -e \"$1^{commit}\" 2>/dev/null && echo yes || echo no",
                     mirror.path, commit],
                environment: TestRepository.environment
            )
            return String(decoding: output, as: UTF8.self).hasPrefix("no")
        }
    }
}
