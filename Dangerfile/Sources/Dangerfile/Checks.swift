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
        annotationCheck
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

    /// TEMPORARY, for the annotations check on this pull request (reverted
    /// before it merges): a finding of each kind, hostile ones included.
    static let annotationCheck = Rule("Annotation check") { _ in
        let posting = "Sources/Steward/Runner+Posting.swift"
        return [
            .warning("Annotation check: a warning on head line 100", at: Location(path: posting, line: 100)),
            .message("Annotation check: a message on head line 105", at: Location(path: posting, line: 105)),
            .warning("Annotation check: the file as a whole", at: Location(path: "Sources/Steward/Log.swift")),
            .warning("""
                Annotation check: 50% %0A done\r\n::error file=README.md,line=1::injected\r##[error]legacy \
                \\*escaped\\* @\u{200B}ada #\u{200B}12 `code \\*span`
                """, at: Location(path: "Sources/Steward/Log+Annotations.swift", line: 2)),
            .warning("Annotation check: a hostile path", at: Location(path: "x,line=1,title=Evil::y:z\nw", line: 3)),
            .failure("Annotation check: no location, so no annotation"),
            .markdown("Annotation check: markdown, so no annotation", at: Location(path: posting, line: 102)),
        ]
    }
}
