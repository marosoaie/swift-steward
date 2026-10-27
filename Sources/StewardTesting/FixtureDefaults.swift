import Foundation

/// The values fixtures fall back on, shared so a default pull request, its
/// default commit, and its context agree.
@usableFromInline
enum FixtureDefaults {
    @usableFromInline static let repository = "octocat/hello-world"
    @usableFromInline static let baseCommit = String(repeating: "ba5e", count: 10)
    @usableFromInline static let headCommit = String(repeating: "4ead", count: 10)
    /// 2026-01-01 00:00:00 UTC: fixed, so a test's output never depends on
    /// when it runs.
    @usableFromInline static let date = Date(timeIntervalSince1970: 1_767_225_600)
    // The literals parse; the fallbacks only spare force unwraps.
    static let apiURL = URL(string: "https://api.github.com") ?? URL(fileURLWithPath: "/")
    static let serverURL = URL(string: "https://github.com") ?? URL(fileURLWithPath: "/")
}
