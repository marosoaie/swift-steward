extension Rule {
    /// The rule's findings, each named after the rule, or one failure that
    /// quotes what the rule, or a condition of a group around it, threw
    /// (docs/danger.md, section 1); none when a group doesn't hold. The
    /// log gets a line saying how many, or why the rule was skipped.
    ///
    /// Throws only when the run's task is cancelled: a rule can't stop the
    /// run, and an error it throws for any other reason, a
    /// `CancellationError` of its own included, is its failure.
    func findings(in context: Context, log: Log) async throws(CancellationError) -> [Finding] {
        let findings: [Finding]
        do {
            if let reason = try skipReason(in: context) {
                log.write("\(name): skipped, \(reason)")
                return []
            }
            findings = try await check(context, log)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            let description = String(errorDescription: error)
            findings = [.failure("Rule “\(Markdown.escaped(name))” failed: \(Markdown.escaped(description))")]
        }
        guard !Task.isCancelled else { throw CancellationError() }
        log.write(logLine(for: findings))
        return findings.map { finding in
            var named = finding
            named.rule = name
            return named
        }
    }

    private func logLine(for findings: [Finding]) -> String {
        let count = findings.count == 1 ? "1 finding" : "\(findings.count) findings"
        let failures = findings.filter { $0.kind == .failure }.count
        return failures == 0 ? "\(name): \(count)" : "\(name): \(count), \(failures) failing"
    }
}

extension [Rule] {
    /// The rules' findings, one rule after another in order.
    func findings(in context: Context, log: Log) async throws(CancellationError) -> [Finding] {
        var findings: [Finding] = []
        // Imperative: each rule awaits the one before it (docs/danger.md,
        // section 1), which `reduce` can't.
        for rule in self {
            guard !Task.isCancelled else { throw CancellationError() }
            findings += try await rule.findings(in: context, log: log)
        }
        return findings
    }
}
