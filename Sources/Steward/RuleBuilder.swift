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
/// to type-check.
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
