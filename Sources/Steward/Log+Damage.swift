import GitDiffKit

extension Log {
    /// Logs the damage the diff parser found in the pull request's diff
    /// (docs/danger.md, section 6). An abandoned file becomes a warning,
    /// since the rules then saw an incomplete diff; a local recovery is a
    /// line of the log.
    func record(_ damage: [DamageReport]) {
        damage.forEach { report in
            switch report.severity {
            case .error: warning(report.explanation)
            case .info: write(report.explanation)
            }
        }
    }
}

extension DamageReport {
    /// Where the diff is damaged, how, and, for an abandoned file, what
    /// that means for the rules, as the run's log says it.
    var explanation: String {
        switch severity {
        case .error: "\(sentence) Steward left the file out, so the rules didn't see it."
        case .info: sentence
        }
    }

    /// Where the diff is damaged, and how, in one sentence.
    package var sentence: String {
        let path = (file?.newPath ?? file?.oldPath).map { " (\($0.string))" } ?? ""
        return "The diff is damaged at line \(lineNumber)\(path): \(Self.text(of: reason))."
    }

    private static func text(of reason: Reason) -> String {
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
