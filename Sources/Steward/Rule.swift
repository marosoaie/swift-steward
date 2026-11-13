/// One check over a pull request: a name and a function from the context
/// to findings.
///
/// Rules are values, so a test calls one with a context and inspects what
/// it returns. The runner calls them one at a time, in the order a
/// `Dangerfile` lists them, and a rule never sees another's findings.
///
/// ```swift
/// Rule("No new Objective-C") { context in
///     context.git.createdFiles
///         .filter { $0.hasSuffix(".m") }
///         .map { .failure("Write \(Markdown.codeSpan($0)) in Swift.", at: Location(path: $0)) }
/// }
/// ```
public struct Rule: Sendable {
    /// Names the rule in the report and the log.
    public var name: String
    /// The check itself, called only where the rule applies.
    ///
    /// A thrown error doesn't stop the run: the runner records a failure
    /// of this rule that quotes the error, and runs the next rule.
    ///
    /// Getting it gives what a run gets: no findings where a group around
    /// the rule doesn't hold (`applies(to:)` tells that from a pass), and
    /// the error a group's condition throws. Setting it replaces the check
    /// and keeps the groups, so the new check runs where the old one did.
    public var evaluate: @Sendable (Context) async throws -> [Finding] {
        get {
            { [self] context in
                guard try applies(to: context) else { return [] }
                return try await check(context, .discarding)
            }
        }
        set { check = { context, _ in try await newValue(context) } }
    }

    /// The check, given the run's log, where a built-in rule says what it
    /// read and skipped, which the summary has no room for.
    var check: @Sendable (Context, Log) async throws -> [Finding]

    /// The conditions of the groups around the rule, outermost first, kept
    /// apart from `check` so that replacing it keeps them.
    var conditions: [Condition] = []

    /// Creates a rule from its name and its check.
    public init(_ name: String, evaluate: @escaping @Sendable (Context) async throws -> [Finding]) {
        self.name = name
        check = { context, _ in try await evaluate(context) }
    }

    /// Creates a rule whose check writes to the run's log.
    init(_ name: String, check: @escaping @Sendable (Context, Log) async throws -> [Finding]) {
        self.name = name
        self.check = check
    }
}
