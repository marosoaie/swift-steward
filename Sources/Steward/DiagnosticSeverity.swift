import BuildLogKit

/// How severe a build or lint diagnostic is, as its tool reported it, from
/// least to most: what `Rule.diagnosticsOnChangedLines(in:failingOn:)`
/// fails on, as `steward filter --fail-on` does.
public enum DiagnosticSeverity: Sendable, Hashable, Comparable {
    /// A note.
    case note
    /// A warning.
    case warning
    /// An error.
    case error

    init(_ severity: Diagnostic.Severity) {
        self = switch severity {
        case .note: .note
        case .warning: .warning
        case .error: .error
        }
    }
}
