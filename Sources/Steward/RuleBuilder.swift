/// Builds a list of rules from statements: rules, arrays of rules (from a
/// helper that adds several at once), `if`, `switch`, and `for`.
///
/// `Dangerfile.rules` uses it, so a conformer lists its rules without
/// writing the attribute:
///
/// ```swift
/// static var rules: [Rule] {
///     Rule("Changelog") { context in … }
///     if requiresTests {
///         Rule("Tests") { context in … }
///     }
///     sharedRules
/// }
/// ```
///
/// It works over the one concrete type `[Rule]`, so long lists stay cheap
/// to type-check. A finding among the rules, outside any rule, doesn't
/// compile, and the compiler says it belongs inside one.
@resultBuilder
public enum RuleBuilder {
    /// One rule.
    public static func buildExpression(_ rule: Rule) -> [Rule] {
        [rule]
    }

    /// Several rules at once, in order.
    public static func buildExpression(_ rules: [Rule]) -> [Rule] {
        rules
    }

    /// A finding outside any rule, which doesn't compile: findings come
    /// from a rule's check.
    ///
    /// A finding on the line after a rule, as in `.warning("…")`, reads as
    /// a member of that rule instead, and gets the compiler's own error.
    @available(*, unavailable, message: "a finding belongs inside a rule: Rule(\"Name\") { context in [finding] }")
    public static func buildExpression(_ finding: Finding) -> [Rule] {
        []
    }

    /// Findings outside any rule, which don't compile: findings come from
    /// a rule's check.
    @available(*, unavailable, message: "findings belong inside a rule: Rule(\"Name\") { context in findings }")
    public static func buildExpression(_ findings: [Finding]) -> [Rule] {
        []
    }

    /// The statements of a block, in order.
    public static func buildBlock(_ components: [Rule]...) -> [Rule] {
        components.flatMap(\.self)
    }

    /// An `if` without an `else`: its rules when the condition holds.
    public static func buildOptional(_ component: [Rule]?) -> [Rule] {
        component ?? []
    }

    /// The first branch of an `if`–`else` or a `switch`.
    public static func buildEither(first component: [Rule]) -> [Rule] {
        component
    }

    /// The second branch of an `if`–`else` or a `switch`.
    public static func buildEither(second component: [Rule]) -> [Rule] {
        component
    }

    /// A `for` loop: every iteration's rules, in order.
    public static func buildArray(_ components: [[Rule]]) -> [Rule] {
        components.flatMap(\.self)
    }

    /// An `if #available` block.
    public static func buildLimitedAvailability(_ component: [Rule]) -> [Rule] {
        component
    }
}
