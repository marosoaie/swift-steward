extension Log {
    /// Annotates each located finding in CI, so it shows on its line in
    /// the pull request's Files changed tab (docs/danger.md, section 6): a
    /// failure as an error, a warning as a warning, and a message as a
    /// notice. Findings without a location, and `markdown` ones, are left
    /// to the summary. A dry run writes none.
    func annotate(_ findings: [Finding]) {
        guard mode == .actions else { return }
        findings.compactMap(Self.annotation(of:)).forEach(console.writeError)
    }

    /// The workflow command that annotates `finding`, or nil when it gets
    /// none. Its text is plain, since GitHub shows an annotation's message
    /// as it is.
    static func annotation(of finding: Finding) -> String? {
        let command: String? = switch finding.kind {
        case .failure: "error"
        case .warning: "warning"
        case .message: "notice"
        case .markdown: nil
        }
        guard let command, let location = finding.location else { return nil }
        // Without a line, it's the whole file's: the check run lists it,
        // but Files changed doesn't show it (docs/danger.md, Checks).
        let line = location.line.map { ",line=\($0)" } ?? ""
        return """
            ::\(command) file=\(escapedProperty(location.path))\(line),title=Steward::\
            \(escapedData(Markdown.unescaped(finding.text)))

            """
    }
}
