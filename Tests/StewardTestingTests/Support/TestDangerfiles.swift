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

/// A Dangerfile whose rule writes to the run's log: a line for each file
/// the pull request creates, and one that could pass for a workflow
/// command.
struct Logging: Dangerfile {
    static let created = Rule("Created") { context, log in
        context.git.createdFiles.forEach { log.write("Created: read \($0)") }
        log.write("::error::forged")
        return context.git.createdFiles.map { .message("A new file.", at: Location(path: $0)) }
    }

    static var rules: [Rule] {
        created
    }
}
