import Foundation

/// Where Steward runs, and on which trees.
public struct Run: Sendable, Hashable {
    /// How Steward was started.
    public enum Mode: Sendable, Hashable {
        /// In a GitHub Actions workflow (`GITHUB_ACTIONS=true`).
        case actions
        /// Anywhere else: a local run that prints its summary and never
        /// posts.
        case dryRun
    }

    /// How Steward was started.
    public var mode: Mode
    /// The checkout's root directory.
    public var workspace: String
    /// The SHA of the commit build logs refer to. In a `pull_request`
    /// workflow that's the merge commit Actions checks out (`GITHUB_SHA`),
    /// not the pull request's head.
    public var builtCommit: String
    /// Maps lines of `builtCommit` to the head commit's, so diagnostics
    /// from a build log can be matched against the pull request's changes.
    /// `LineMap.identity` when the built commit is the head.
    public var lineMap: LineMap
    /// The root of the host's REST API: `https://api.github.com`, or a
    /// GitHub Enterprise Server's (`GITHUB_API_URL`).
    public var apiURL: URL
    /// The root of the host's website, for links: `https://github.com`, or
    /// a GitHub Enterprise Server's (`GITHUB_SERVER_URL`).
    public var serverURL: URL

    /// Creates a run from its parts.
    public init(
        mode: Mode,
        workspace: String,
        builtCommit: String,
        lineMap: LineMap,
        apiURL: URL,
        serverURL: URL
    ) {
        self.mode = mode
        self.workspace = workspace
        self.builtCommit = builtCommit
        self.lineMap = lineMap
        self.apiURL = apiURL
        self.serverURL = serverURL
    }
}
