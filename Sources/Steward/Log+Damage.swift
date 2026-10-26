import GitDiffKit

extension Log {
    /// Logs the damage the diff parser found in the pull request's diff
    /// (docs/danger.md, section 6). An abandoned file becomes a warning,
    /// since the rules then saw an incomplete diff; a local recovery is a
    /// line of the log.
    func record(_ damage: [DamageReport]) {
        damage.forEach { report in
            switch report.severity {
            case .error: warning(Self.text(of: report))
            case .info: write(Self.text(of: report))
            }
        }
    }

    static func text(of report: DamageReport) -> String {
        let path = (report.file?.newPath ?? report.file?.oldPath).map { " (\($0.string))" } ?? ""
        let consequence = switch report.severity {
        case .error: " Steward left the file out, so the rules didn't see it."
        case .info: ""
        }
        return "The diff is damaged at line \(report.lineNumber)\(path): \(reason(of: report.reason)).\(consequence)"
    }

    private static func reason(of reason: DamageReport.Reason) -> String {
        switch reason {
        case .hunkCutShort: "a hunk ends before its line counts are used up"
        case .missingLineMarker: "a hunk line has no +, -, or space marker"
        case .misplacedNoNewlineMarker: "a \"\\ No newline at end of file\" line is out of place"
        case .ignoredHeaderValue: "a value in the file's header doesn't parse"
        case .malformedHunkHeader: "an @@ line isn't a valid hunk header"
        case .hunkWithoutFile: "a hunk comes before any file header"
        case .malformedBinaryPatch: "a binary patch ends early"
        case .headerTooLarge: "the file's header is too large"
        case .tooManyParents: "a combined diff has more than 64 parents"
        }
    }
}
