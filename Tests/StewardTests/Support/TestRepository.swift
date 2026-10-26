import Foundation

/// A git repository in a fresh temporary directory, built with git's global
/// and system configuration shut out and with fixed names and dates, so the
/// same steps make the same commits on every machine.
///
/// Call `remove()` when done.
struct TestRepository {
    /// The temporary directory holding the repository, and the event
    /// payload a run reads beside it.
    let root: URL
    /// The repository's working tree, or the repository itself when bare.
    let url: URL

    var path: String { url.path }
    var eventURL: URL { root.appendingPathComponent("event.json") }

    /// What every git command that builds a fixture runs with.
    static let environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Ada Lovelace",
        "GIT_AUTHOR_EMAIL": "ada@example.com",
        "GIT_COMMITTER_NAME": "Charles Babbage",
        "GIT_COMMITTER_EMAIL": "charles@example.com",
    ]

    /// The test process's environment without the variables Actions and
    /// git read, then `environment`, then `variables`: what a run under
    /// test sees.
    static func runEnvironment(adding variables: [String: String]) -> [String: String] {
        ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("GITHUB_") && !$0.key.hasPrefix("GIT_") }
            .merging(environment) { $1 }
            .merging(variables) { $1 }
    }

    /// An empty repository whose first branch is `main`.
    init(bare: Bool = false) throws {
        try self.init(creatingIn: Self.temporaryRoot())
        try git(["init", "--quiet", "--initial-branch=main"] + (bare ? ["--bare"] : []))
    }

    /// A clone of `source`, with `options` such as `--depth=1`.
    init(cloning source: TestRepository, options: [String] = []) throws {
        // A file:// URL, so `--depth` makes a real shallow clone rather than
        // hard-linking every object.
        try self.init(cloning: source.url.absoluteString, options: options)
    }

    /// A clone of the repository at `source`, a path or URL.
    init(cloning source: String, options: [String] = []) throws {
        let root = try Self.temporaryRoot()
        let destination = root.appendingPathComponent("repository").path
        _ = try Subprocess.output(
            of: ["git", "clone", "--quiet"] + options + [source, destination],
            environment: Self.environment
        )
        try self.init(creatingIn: root)
    }

    private init(creatingIn root: URL) throws {
        self.root = root
        url = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs git in the repository and returns its output, without the
    /// final newline.
    @discardableResult
    func git(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let output = try Subprocess.output(
            of: ["git", "-C", path] + arguments,
            environment: Self.environment.merging(environment) { $1 }
        )
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// Runs git in the repository and returns its output's bytes.
    func gitBytes(_ arguments: [String]) throws -> Data {
        try Subprocess.output(of: ["git", "-C", path] + arguments, environment: Self.environment)
    }

    func write(_ contents: String, to path: String) throws {
        try write(Data(contents.utf8), to: path)
    }

    func write(_ contents: Data, to path: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file)
    }

    /// Commits the whole working tree, dated `time` seconds after the epoch,
    /// and returns the commit's SHA.
    @discardableResult
    func commit(_ message: String, at time: Int) throws -> String {
        try git(["add", "--all"])
        return try commitIndex(message, at: time)
    }

    /// Commits the index as it stands, without adding the working tree.
    @discardableResult
    func commitIndex(_ message: String, at time: Int) throws -> String {
        try git(
            ["commit", "--quiet", "--allow-empty", "--no-verify", "--message", message],
            environment: ["GIT_AUTHOR_DATE": "@\(time) +0000", "GIT_COMMITTER_DATE": "@\(time) +0000"]
        )
        return try git(["rev-parse", "HEAD"])
    }

    /// Merges `branch` into the current branch with a merge commit, dated
    /// `time`, and returns its SHA.
    @discardableResult
    func merge(_ branch: String, at time: Int) throws -> String {
        try git(
            ["merge", "--quiet", "--no-ff", "--no-edit", branch],
            environment: ["GIT_AUTHOR_DATE": "@\(time) +0000", "GIT_COMMITTER_DATE": "@\(time) +0000"]
        )
        return try git(["rev-parse", "HEAD"])
    }

    /// The environment of an Actions run for a `pull_request` event from
    /// `base` to `head` that checked out `built`, with the event's payload
    /// written beside the repository.
    func actionsEnvironment(
        action: String = "opened",
        base: String,
        head: String,
        built: String? = nil
    ) throws -> [String: String] {
        let payload = try EventPayload.recorded("pull-request-event.opened")
            .setting(action: action, base: base, head: head)
        try payload.write(to: eventURL)
        return [
            "GITHUB_ACTIONS": "true",
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_EVENT_PATH": eventURL.path,
            "GITHUB_WORKSPACE": path,
            "GITHUB_SHA": built ?? head,
        ]
    }

    /// A repository whose one commit is the base, head, and built commit,
    /// and that commit's SHA.
    static func singleCommit() throws -> (TestRepository, String) {
        let repository = try TestRepository()
        try repository.write("one\n", to: "a.swift")
        return (repository, try repository.commit("One", at: PullRequestFixture.time))
    }
}
