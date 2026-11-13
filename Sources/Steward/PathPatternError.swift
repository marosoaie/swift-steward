/// Why a `PathPattern` can't be matched: what a rule that uses it fails
/// with.
enum PathPatternError: Error, Equatable, CustomStringConvertible {
    case empty
    case leadingSlash(String)
    /// An empty, `.` or `..` component, which git would rewrite away.
    case component(String, component: String)
    case unescapedBracket(String)
    case trailingBackslash(String)
    /// A `**` with something other than `/` or an end on either side.
    case partialGlobstar(String)

    var description: String {
        switch self {
        case .empty:
            "The path pattern is empty; write ** for every file."
        case .leadingSlash(let pattern):
            "The path pattern “\(pattern)” starts with “/”; patterns start at the repository's root without one."
        case .component(let pattern, component: ""):
            "The path pattern “\(pattern)” has an empty component."
        case .component(let pattern, let component):
            "The path pattern “\(pattern)” has a “\(component)” component; write the path without it."
        case .unescapedBracket(let pattern):
            """
            The path pattern “\(pattern)” has an unescaped “[”; classes aren't supported, \
            so write \\[ for a literal one.
            """
        case .trailingBackslash(let pattern):
            "The path pattern “\(pattern)” ends with a “\\” that escapes nothing."
        case .partialGlobstar(let pattern):
            """
            The path pattern “\(pattern)” has a “**” that isn't a whole component, as in a/**/b; \
            use * within a component.
            """
        }
    }
}
