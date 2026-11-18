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

/// A Dangerfile whose per-file rule writes a line for each file it reads,
/// with a limit that has it skip Sources/New.swift in `SampleDiff.created`,
/// a warning.
struct PerFileLogging: Dangerfile {
    static let sizes = Rule.changedFiles("Sizes", in: "**", limit: 10) { file, log in
        log.write("Sizes: read \(file.path)")
        return [.message("\(file.contents.count) bytes", at: Location(path: file.path))]
    }

    static var rules: [Rule] {
        sizes
    }
}

/// `PerFileLogging`'s rule with a check that skips an empty file itself,
/// in the words the rule uses for the files it skips, as a message.
struct OwnSkips: Dangerfile {
    static var rules: [Rule] {
        Rule.changedFiles("Sizes", in: "**", limit: 10) { file, log in
            guard !file.contents.isEmpty else {
                log.write("Sizes: skipped \(file.path), an empty file")
                return [.skipped(file.path, "an empty file", by: "Sizes", as: .message)]
            }
            return [.message("\(file.contents.count) bytes", at: Location(path: file.path))]
        }
    }
}
