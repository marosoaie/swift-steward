import Foundation
import Steward

extension FixtureChecks {
    /// Names the reports for the diagnostics rule, one per line: a tool
    /// (`xcodebuild`, `swiftlint`, `swiftformat`, or `sonar`), the report's
    /// path, and optionally the commit it was built at, separated by tabs.
    static let diagnosticsVariable = "STEWARD_FIXTURE_DIAGNOSTICS"

    /// The reports `diagnosticsVariable` names, or nil when it's unset, so
    /// the runs on real pull requests keep their pinned findings.
    static var diagnosticSources: [DiagnosticSource]? {
        ProcessInfo.processInfo.environment[diagnosticsVariable].map { variable in
            variable.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 2 || fields.count == 3 else { return nil }
                let commit = fields.count == 3 ? fields[2] : nil
                return switch fields[0] {
                case "xcodebuild": .xcodebuild(fields[1], builtAt: commit)
                case "swiftlint": .swiftLint(fields[1], builtAt: commit)
                case "swiftformat": .swiftFormat(fields[1], builtAt: commit)
                case "sonar": .sonar(fields[1], builtAt: commit)
                default: nil
                }
            }
        }
    }
}
