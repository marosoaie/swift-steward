/// A single compiler/linter diagnostic extracted from a build or lint log.
public struct Diagnostic: Sendable, Hashable, Codable {
    /// How serious a diagnostic is, from a note up to an error.
    public enum Severity: String, Sendable, Codable, CaseIterable, Comparable {
        /// Information, such as where a declaration is; clang's `remark:`
        /// too.
        case note
        /// A problem that doesn't fail the build.
        case warning
        /// A problem that fails the build; clang's `fatal error:` too.
        case error

        private var rank: Int {
            switch self {
            case .note: 0
            case .warning: 1
            case .error: 2
            }
        }

        /// Whether `lhs` is less serious than `rhs`.
        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// Path exactly as it appeared in the log (usually absolute for Xcode
    /// and SwiftLint, relative for some other tools); nil for an error the
    /// log doesn't place, such as a linker's.
    public var path: String?
    /// The 1-based line in `path`; nil when the log doesn't place the
    /// diagnostic.
    public var line: Int?
    /// The 1-based column, when the log gives one.
    public var column: Int?
    /// How serious the tool says the diagnostic is.
    public var severity: Severity
    /// The tool's message, without the location and severity before it.
    public var message: String
    /// The rule or flag that produced the diagnostic, when the tool-specific
    /// parser could extract one: a SwiftLint rule identifier
    /// (`line_length`), a SwiftFormat rule name (`indent`), or a clang
    /// warning flag (`-Wunused-variable`). Nil for the generic parser.
    public var rule: String?

    /// Creates a diagnostic from its parts; one without a location has a
    /// nil `path` and `line`.
    public init(
        path: String?,
        line: Int?,
        column: Int? = nil,
        severity: Severity,
        message: String,
        rule: String? = nil
    ) {
        self.path = path
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
        self.rule = rule
    }
}
