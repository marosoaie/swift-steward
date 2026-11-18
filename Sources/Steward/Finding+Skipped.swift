extension Finding {
    /// A finding that says the rule named `rule` skipped the file at
    /// `path`, and why, at the file: the sentence `Rule.changedFiles`
    /// reports for each file it skips, so a check's own skips read the same.
    ///
    /// ```swift
    /// Rule.changedFiles("Licence header", in: "Sources/**/*.swift") { file, log in
    ///     guard !file.contents.starts(with: Array("// Generated".utf8)) else {
    ///         log.write("Licence header: skipped \(file.path), a generated file")
    ///         return [.skipped(file.path, "a generated file", by: "Licence header", as: .message)]
    ///     }
    ///     return file.contents.starts(with: Array("// SPDX-License-Identifier:".utf8))
    ///         ? [] : [.warning("Start with the licence header.", at: Location(path: file.path, line: 1))]
    /// }
    /// ```
    ///
    /// The text is "Rule “`rule`” skipped `path`, `reason`. A file the rule
    /// should never check belongs in its `excluding:` pattern.", which fits
    /// a rule that has that pattern, as `Rule.changedFiles` and the rules
    /// built on it do. The rule's name is escaped and the path is a code
    /// span, so neither renders as Markdown or mentions anyone. `reason`
    /// goes in as written, as Markdown, after a comma, so an appositive
    /// reads best: "a generated file", "with syntax errors". Text from the
    /// pull request in it goes through `Markdown.escaped(_:)` first.
    ///
    /// It writes nothing to the run's log: a check that logs its skips, as
    /// `Rule.changedFiles` does, writes the line itself.
    public static func skipped(_ path: String, _ reason: String, by rule: String, as kind: Kind = .warning) -> Finding {
        Finding(kind: kind, text: skippedText(path, reason, by: rule), location: Location(path: path))
    }

    /// The text of `skipped(_:_:by:as:)`, for the file `name` names, which
    /// `Rule.changedFiles` builds its own skips' from too. A file over the
    /// rule's limit is checked once the limit is raised, which is what a
    /// source file usually needs, so its text says that first.
    static func skippedText(_ name: String, _ reason: String, by rule: String, isOverLimit: Bool = false) -> String {
        let raising = isOverLimit ? "Raising the rule's `limit:` has it checked; a file" : "A file"
        return """
            Rule “\(Markdown.escaped(rule))” skipped \(Markdown.codeSpan(name)), \(reason). \(raising) the \
            rule should never check belongs in its `excluding:` pattern.
            """
    }
}
