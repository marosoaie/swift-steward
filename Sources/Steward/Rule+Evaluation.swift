extension Rule {
    /// The rule's findings, each named after the rule, or one failure that
    /// quotes what the rule threw (docs/danger.md, section 1).
    ///
    /// Throws only when the run's task is cancelled: a rule can't stop the
    /// run, and an error it throws for any other reason, a
    /// `CancellationError` of its own included, is its failure.
    func findings(in context: Context, log: Log) async throws(CancellationError) -> [Finding] {
        let findings: [Finding]
        do {
            findings = try await check(context, log)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            let description = String(errorDescription: error)
            findings = [.failure("Rule “\(Markdown.escaped(name))” failed: \(Markdown.escaped(description))")]
        }
        guard !Task.isCancelled else { throw CancellationError() }
        return findings.map { finding in
            var named = finding
            named.rule = name
            return named
        }
    }
}

extension [Rule] {
    /// The rules' findings, one rule after another in order, each logged
    /// with how many findings it returned.
    func findings(in context: Context, log: Log) async throws(CancellationError) -> [Finding] {
        var findings: [Finding] = []
        // Imperative: each rule awaits the one before it (docs/danger.md,
        // section 1), which `reduce` can't.
        for rule in self {
            guard !Task.isCancelled else { throw CancellationError() }
            let ruleFindings = try await rule.findings(in: context, log: log)
            log.write(Self.logLine(for: rule, findings: ruleFindings))
            findings += ruleFindings
        }
        return findings
    }

    private static func logLine(for rule: Rule, findings: [Finding]) -> String {
        let count = findings.count == 1 ? "1 finding" : "\(findings.count) findings"
        let failures = findings.filter { $0.kind == .failure }.count
        return failures == 0 ? "\(rule.name): \(count)" : "\(rule.name): \(count), \(failures) failing"
    }
}
