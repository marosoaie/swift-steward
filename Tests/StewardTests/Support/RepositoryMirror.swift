import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

extension RepositoryMirror {
    /// A mirror of the public GitHub repository `owner/name` without its
    /// blobs: the commits and trees behind `tags`, fetched once into the
    /// fixture cache, with each blob fetched the first time git reads it.
    ///
    /// For repositories too large to clone whole, such as redis/redis.
    static func upstream(_ repository: String, tags: [String]) throws -> URL {
        try refreshing.withLock { _ in
            let mirror = directory.appendingPathComponent("upstream/\(repository).git", isDirectory: true)
            if !FileManager.default.fileExists(atPath: mirror.path) {
                try FileManager.default.createDirectory(
                    at: mirror.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Built beside the mirror, then moved into place, so an
                // interrupted fetch never looks like a mirror.
                let partial = mirror.deletingLastPathComponent()
                    .appendingPathComponent(".\(mirror.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: partial) }
                try [
                    ["init", "--quiet", "--bare", partial.path],
                    ["-C", partial.path, "remote", "add", "origin", "https://github.com/\(repository).git"],
                    ["-C", partial.path, "config", "remote.origin.promisor", "true"],
                    ["-C", partial.path, "config", "remote.origin.partialclonefilter", "blob:none"],
                ].forEach { try git($0) }
                try fetch(tags, into: partial)
                try? FileManager.default.moveItem(at: partial, to: mirror)
            }
            let missing = try tags.filter { tag in
                let output = try Subprocess.output(
                    of: ["sh", "-c", """
                        git -C "$0" rev-parse --verify --quiet "refs/tags/$1" >/dev/null && echo yes || echo no
                        """, mirror.path, tag],
                    environment: TestRepository.environment
                )
                return String(decoding: output, as: UTF8.self).hasPrefix("no")
            }
            if !missing.isEmpty {
                try fetch(missing, into: mirror)
            }
            return mirror
        }
    }

    private static func fetch(_ tags: [String], into mirror: URL) throws {
        try git(["-C", mirror.path, "fetch", "--quiet", "--filter=blob:none", "--no-tags", "origin"]
            + tags.map { "refs/tags/\($0):refs/tags/\($0)" })
    }

    private static func git(_ arguments: [String]) throws {
        _ = try Subprocess.output(
            of: ["git"] + arguments,
            environment: TestRepository.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
        )
    }

    /// GitHub's diff of `base...head` in `owner/name`, as its compare page
    /// serves it, from the fixture cache, or downloaded into it first.
    ///
    /// Named as SwiftStewardTests' `RealWorldFixtureStore` names its
    /// copies, `<name>-<base>-to-<head>.diff`, so the two share them.
    static func compareDiff(of repository: String, from base: String, to head: String) async throws -> String {
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        let cached = directory.deletingLastPathComponent().appendingPathComponent("\(name)-\(base)-to-\(head).diff")
        if let data = try? Data(contentsOf: cached), data.prefix(4096).contains(Data("diff --git".utf8)) {
            return String(decoding: data, as: UTF8.self)
        }
        guard let url = URL(string: "https://github.com/\(repository)/compare/\(base)...\(head).diff") else {
            throw FixtureError("no compare URL for \(repository) \(base)...\(head)")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, data.prefix(4096).contains(Data("diff --git".utf8)) else {
            throw FixtureError("GET \(url) answered \(status), not a diff; try again, or check the URL")
        }
        try FileManager.default.createDirectory(
            at: cached.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: cached, options: .atomic)
        return String(decoding: data, as: UTF8.self)
    }
}
