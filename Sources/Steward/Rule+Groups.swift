extension Rule {
    /// Rules that run only when a file the pull request changes matches
    /// `pattern`; otherwise the run skips them, logging `Name: skipped, no
    /// changed file matches <pattern>`.
    ///
    /// ```swift
    /// Rule.group(whenChangesMatch: "mbk/**") {
    ///     MBKImagesRule.rule
    ///     MBKStringsRule.rule
    /// }
    /// ```
    ///
    /// A file counts by either path, as `GitChanges.changes(matching:)`
    /// matches it: a created or modified file, a deleted file by its old
    /// path, a renamed file by either, and a copy by its new path. A
    /// damaged diff runs the rules, since a file it lost might match. A
    /// malformed pattern is each rule's failure, and none of them runs.
    ///
    /// Groups nest, and a rule runs only where every group around it
    /// holds. A rule placed in two groups runs once for each that holds,
    /// and reports its findings each time.
    public static func group(whenChangesMatch pattern: PathPattern, @RuleBuilder _ rules: () -> [Rule]) -> [Rule] {
        group(
            when: { context in
                let matcher = try PathMatcher(pattern)
                return context.git.diff.files.contains(where: matcher.matches) || !context.git.diff.damage.isEmpty
            },
            skipReason: "no changed file matches \(pattern)",
            rules
        )
    }

    /// Rules that run only when `condition` holds for the context;
    /// otherwise the run skips them, logging `Name: skipped, <skipReason>`.
    ///
    /// ```swift
    /// Rule.group(when: isReadyForReview, skipReason: "the pull request is a draft") {
    ///     ReviewReadinessRule.rule
    /// }
    ///
    /// static func isReadyForReview(_ context: Context) -> Bool {
    ///     !context.pullRequest.isDraft
    /// }
    /// ```
    ///
    /// A named condition, as here, keeps SwiftLint's default
    /// `multiple_closures_with_trailing_closure` quiet, which flags an
    /// inline closure before the trailing one.
    ///
    /// What `condition` throws is each rule's failure, and none of them
    /// runs. Groups nest, and a rule runs only where every group around
    /// it holds; the run checks the outermost first, and logs the reason
    /// of the first that doesn't. A rule placed in two groups runs once
    /// for each that holds, and reports its findings each time.
    public static func group(
        when condition: @escaping @Sendable (Context) throws -> Bool,
        skipReason: String,
        @RuleBuilder _ rules: () -> [Rule]
    ) -> [Rule] {
        rules().map { rule in
            var grouped = rule
            grouped.conditions.insert(Condition(holds: condition, skipReason: skipReason), at: 0)
            return grouped
        }
    }

    /// Whether the run calls the rule for `context`: whether every group
    /// around it holds. A rule in no group always applies.
    ///
    /// Throws what a group's condition throws, such as the error for a
    /// malformed path pattern, which a run reports as the rule's failure.
    public func applies(to context: Context) throws -> Bool {
        try skipReason(in: context) == nil
    }

    /// The skip reason of the outermost group around the rule that doesn't
    /// hold for `context`, or nil when they all do.
    func skipReason(in context: Context) throws -> String? {
        try conditions.first { try !$0.holds(context) }?.skipReason
    }
}
