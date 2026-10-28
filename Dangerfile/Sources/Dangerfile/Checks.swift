import Steward

/// The rules Steward checks this repository's pull requests with, in the
/// order they run and their findings show.
///
/// pr.yml's tests-and-diagnostics job runs them through steward-action,
/// which posts the summary as a comment on the pull request; anywhere else,
/// `swift run --package-path Dangerfile` is a dry run that prints it.
@main
struct Checks: Dangerfile {
    static var rules: [Rule] {
        diagnostics
        releaseVersion
        thirdPartyNotices
    }

    /// The build's and SwiftLint's diagnostics on the lines the pull request
    /// changes, from the logs the job writes before it runs Steward. Warnings
    /// fail too, as `steward filter --fail-on warning` did: the build has
    /// none, and SwiftLint prints nothing (AGENTS.md).
    static let diagnostics = Rule.diagnosticsOnChangedLines(
        in: [.xcodebuild("build.log"), .swiftLint("swiftlint.log")],
        failingOn: .warning
    )

    /// The file that holds `Release.version`, which only the release
    /// procedure changes (AGENTS.md).
    static let releaseFile = "Sources/StewardVersion/Release.swift"

    /// A pull request that changes the release version gets a warning,
    /// since only a release pull request, which the maintainer asks for,
    /// changes it.
    static let releaseVersion = Rule("Release version") { context in
        guard context.git.modifiedFiles.contains(releaseFile) else { return [] }
        return [.warning("""
            Only a release pull request changes `Release.version`, through the release procedure in \
            AGENTS.md: check that this is one.
            """, at: Location(path: releaseFile))]
    }

    /// Material from another project comes with its licence and an entry in
    /// THIRD_PARTY_NOTICES.md (AGENTS.md), so a pull request that adds a
    /// licence or notice file without touching that list gets a warning at
    /// each one.
    static let thirdPartyNotices = Rule("Third-party notices") { context in
        let git = context.git
        guard !(git.createdFiles + git.modifiedFiles).contains("THIRD_PARTY_NOTICES.md") else { return [] }
        return git.createdFiles.filter(isLicence).map { path in
            .warning("Add an entry to THIRD_PARTY_NOTICES.md for the material this covers.", at: Location(path: path))
        }
    }

    /// Whether the file at `path` is a licence or a notice, by the names
    /// projects give them: `LICENSE`, `LICENCE.md`, `COPYING`, `NOTICE.txt`.
    static func isLicence(_ path: String) -> Bool {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map { $0.uppercased() } ?? ""
        return ["LICENSE", "LICENCE", "COPYING", "NOTICE"].contains { name.hasPrefix($0) }
    }
}
