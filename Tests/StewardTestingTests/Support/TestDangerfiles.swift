import StewardTesting

/// A Dangerfile that finds nothing.
struct Quiet: Dangerfile {
    static var rules: [Rule] {
        Rule("Nothing") { _ in [] }
    }
}

/// A Dangerfile whose summary is far longer than a small host takes.
struct Verbose: Dangerfile {
    static var rules: [Rule] {
        Rule("Many") { _ in
            (1...200).map { .warning("Warning \($0), with enough words to take up room in the summary.") }
        }
    }
}

/// A Dangerfile with only the built-in diagnostics rule, on the
/// workspace's `build.log`.
struct BuildChecks: Dangerfile {
    static var rules: [Rule] {
        Rule.diagnosticsOnChangedLines(in: [.xcodebuild("build.log")])
    }
}
