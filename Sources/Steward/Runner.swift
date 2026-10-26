import Foundation
import GitDiffKit
import GitHubAPI
import PullRequestHosting
import StewardVersion

/// A Dangerfile's whole run (docs/danger.md, section 6): the options, the
/// context, the rules, the report, the summary, and the exit status.
///
/// Its inputs are values, so tests run it in-process against fixture
/// repositories, payloads, and hosts.
struct Runner: Sendable {
    /// Makes the host a run reads a pull request through: the API's root,
    /// the repository's owner and name, and a token, if any.
    typealias HostFactory = @Sendable (
        _ apiURL: URL,
        _ owner: String,
        _ repository: String,
        _ token: String?
    ) -> any PullRequestHost

    /// The arguments after the program's name.
    var arguments: [String]
    /// The program's name, for the help text.
    var program: String
    var environment: [String: String]
    /// The directory relative paths start from: `--report`'s, and in a dry
    /// run the checkout's.
    var currentDirectory: String
    var console: Console
    var makeHost: HostFactory
    var makeToken: @Sendable () -> String = { UUID().uuidString }

    /// What a run's report names as its generator: Steward and the release
    /// `steward --version` prints.
    static let generator = "Steward \(Release.version)"

    /// The runner of this process: its arguments, environment, directory,
    /// standard streams, and GitHub's API.
    static func standard() -> Runner {
        let arguments = CommandLine.arguments
        return Runner(
            arguments: Array(arguments.dropFirst()),
            program: arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Dangerfile",
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: FileManager.default.currentDirectoryPath,
            console: .standard,
            makeHost: { apiURL, owner, repository, token in
                GitHubHost(owner: owner, repository: repository, token: token, apiURL: apiURL)
            }
        )
    }

    /// Runs `rules` over the pull request and says how the run should
    /// exit.
    func run(_ rules: [Rule]) async -> ExitStatus {
        let mode: Run.Mode = environment["GITHUB_ACTIONS"] == "true" ? .actions : .dryRun
        let log = Log(mode: mode, console: console, makeToken: makeToken)
        let options: Options
        do {
            options = try Options(arguments: arguments)
        } catch {
            log.error("\(error) Run \(program) --help for the options.")
            return .broken
        }
        if options.showsHelp {
            console.writeOutput(Options.usage(program: program))
            return .clean
        }
        guard let context = await context(mode: mode, options: options, log: log) else { return .broken }

        let findings: [Finding]
        do {
            findings = try await log.group("Rules") { () async throws(CancellationError) in
                try await rules.findings(in: context, log: log)
            }
        } catch {
            log.error("The run was cancelled, so Steward stopped before writing a report or a summary.")
            return .broken
        }
        let report = Report(
            repository: context.pullRequest.base.repository,
            pullRequest: context.pullRequest.number,
            headCommit: context.git.head,
            findings: findings,
            generator: Self.generator
        )
        let wroteReport = options.reportPath.map { write(report, to: $0, log: log) } ?? true
        await publish(summary(of: report, in: context, options: options), mode: mode, log: log)
        return max(report.hasFailures ? .failures : .clean, wroteReport ? .clean : .broken)
    }

    /// The run's context, with what it's made of and the diff's damage
    /// logged, or nil, with the reason logged as an error.
    private func context(mode: Run.Mode, options: Options, log: Log) async -> Context? {
        if mode == .actions, options.base != nil || options.pullRequest != nil {
            log.warning("""
                --base and --pull-request are for dry runs, so this run ignores them: in GitHub Actions, \
                the pull request comes from the event.
                """)
        }
        do {
            return try await log.group("Context") {
                let context = switch mode {
                case .actions: try await Context.actions(environment: environment)
                case .dryRun: try await Context.dryRun(
                    options: options,
                    environment: environment,
                    directory: currentDirectory,
                    makeHost: makeHost
                )
                }
                log.write(Self.description(of: context))
                log.record(context.git.diff.damage)
                return context
            }
        } catch {
            log.error(String(errorDescription: error))
            return nil
        }
    }

    private static func description(of context: Context) -> String {
        let pullRequest = context.pullRequest
        let files = context.git.diff.files.count
        let commits = context.git.commits.count
        let built = context.run.builtCommit == context.git.head ? "the head" : context.run.builtCommit
        return """
            Pull request #\(pullRequest.number) in \(pullRequest.base.repository): \
            \(pullRequest.head.name) into \(pullRequest.base.name)
            Changes from the merge base \(context.git.mergeBase) to the head \(context.git.head): \
            \(files == 1 ? "1 file" : "\(files) files"), \(commits == 1 ? "1 commit" : "\(commits) commits")
            Build logs refer to \(built).
            """
    }

    /// Writes the report as JSON to `path`, relative to the current
    /// directory, and says whether that worked.
    private func write(_ report: Report, to path: String, log: Log) -> Bool {
        let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
        do {
            try report.encoded().write(to: url, options: .atomic)
            return true
        } catch {
            log.error("Couldn't write the report to \(url.path): \(String(errorDescription: error))")
            return false
        }
    }

    private func summary(of report: Report, in context: Context, options: Options) -> Summary {
        let changes = context.git
        let headPaths = Set(changes.createdFiles + changes.modifiedFiles + changes.renamedFiles.map(\.to))
        let origin: Summary.Origin = switch context.run.mode {
        case .actions: .workflowRun(workflowRunURL(serverURL: context.run.serverURL))
        case .dryRun: .dryRun(isPlaceholder: options.pullRequest == nil)
        }
        return Summary(
            report: report,
            serverURL: context.run.serverURL,
            origin: origin,
            // Links go to the head commit, which lacks these.
            unlinkedPaths: Set(changes.deletedFiles + changes.renamedFiles.map(\.from)).subtracting(headPaths)
        )
    }

    /// The workflow run's page, from the variables Actions sets, or nil
    /// when one is missing or malformed.
    private func workflowRunURL(serverURL: URL) -> URL? {
        let parts = environment["GITHUB_REPOSITORY"]?.split(separator: "/", omittingEmptySubsequences: false) ?? []
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              let runID = environment["GITHUB_RUN_ID"], !runID.isEmpty,
              runID.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        let server = serverURL.absoluteString.hasSuffix("/")
            ? String(serverURL.absoluteString.dropLast())
            : serverURL.absoluteString
        let repository = parts.map { Markdown.percentEncoded(String($0)) }.joined(separator: "/")
        return URL(string: "\(server)/\(repository)/actions/runs/\(runID)")
    }

    /// Shows the summary: in CI, in the log and appended to the job
    /// summary; in a dry run, on standard output.
    private func publish(_ summary: Summary, mode: Run.Mode, log: Log) async {
        let text = summary.text
        switch mode {
        case .dryRun:
            console.writeOutput(text)
        case .actions:
            await log.group("Summary") { log.write(text) }
            appendToJobSummary(text, log: log)
        }
    }

    /// Appends `text` to the file at `GITHUB_STEP_SUMMARY`, which GitHub
    /// shows on the run's page. Without it, the findings are still in the
    /// log, so a failure here is only a warning.
    private func appendToJobSummary(_ text: String, log: Log) {
        guard let path = environment["GITHUB_STEP_SUMMARY"], !path.isEmpty else {
            log.warning("GITHUB_STEP_SUMMARY isn't set, so the findings are in this log only.")
            return
        }
        do {
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
                }
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            // A blank line ends whatever came before, even a table whose
            // last line has no line break.
            let separator = try handle.seekToEnd() > 0 ? "\n\n" : ""
            try handle.write(contentsOf: Data((separator + text).utf8))
        } catch {
            log.warning("Couldn't write the job summary to \(path): \(String(errorDescription: error))")
        }
    }
}
