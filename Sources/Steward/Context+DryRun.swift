import Foundation
import PullRequestHosting

extension Context {
    /// The reference a dry run's base defaults to: the `origin` remote's
    /// default branch.
    static let defaultBase = "refs/remotes/origin/HEAD"

    /// Builds the context of a dry run (docs/danger.md, section 2) from the
    /// git checkout around `directory`, with no API call unless
    /// `--pull-request` asks for one.
    ///
    /// The head is `HEAD`, which is also the built commit, so the line map
    /// is the identity. The base is `--base`, or else the `origin` remote's
    /// default branch. The repository is `GITHUB_REPOSITORY`'s, or else the
    /// `origin` remote's when it's on `GITHUB_SERVER_URL`'s host; without
    /// either, it's empty, and the summary has no links. An SSH host alias
    /// (`github-work:o/r`) doesn't name the server's host, so a checkout
    /// whose `origin` uses one gets its repository by setting
    /// `GITHUB_REPOSITORY`. The pull request
    /// is read through `makeHost` with `--pull-request`, or else it's a
    /// placeholder built from the head commit.
    static func dryRun(
        options: Options,
        environment: [String: String],
        directory: String,
        makeHost: Runner.HostFactory
    ) async throws -> Context {
        let variables = ActionsVariables(environment)
        let apiURL = try variables.url("GITHUB_API_URL", default: "https://api.github.com")
        let serverURL = try variables.url("GITHUB_SERVER_URL", default: "https://github.com")
        let workspace = try await Git(directory: directory, environment: environment).topLevel()
        let git = Git(directory: workspace, environment: environment)
        guard let head = try await git.commit(named: "HEAD") else { throw ContextError.unbornHead }
        let baseReference = options.base ?? defaultBase
        guard let base = try await git.commit(named: baseReference) else {
            throw options.base.map(ContextError.unknownBase) ?? ContextError.noDefaultBase
        }
        let changes = try await GitChanges(base: base, head: head, git: git)
        let repository = try await repository(environment: environment, serverURL: serverURL, git: git)

        let pullRequest = if let number = options.pullRequest {
            try await read(number, from: repository, environment: environment, makeHost: makeHost)
        } else {
            try await placeholder(for: changes, base: base, named: baseReference, repository: repository, git: git)
        }
        return Context(
            pullRequest: pullRequest,
            git: changes,
            run: Run(
                mode: .dryRun,
                workspace: workspace,
                builtCommit: head,
                lineMap: .identity,
                apiURL: apiURL,
                serverURL: serverURL
            )
        )
    }

    private static func read(
        _ number: Int,
        from repository: RepositoryName?,
        environment: [String: String],
        makeHost: Runner.HostFactory
    ) async throws -> PullRequest {
        let variables = ActionsVariables(environment)
        let apiURL = try variables.url("GITHUB_API_URL", default: "https://api.github.com")
        guard let repository else {
            let serverURL = try variables.url("GITHUB_SERVER_URL", default: "https://github.com")
            throw ContextError.unknownRepository(host: serverURL.host ?? "")
        }
        let token = environment["GITHUB_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        do {
            return try await makeHost(apiURL, repository.owner, repository.name, token).pullRequest(number: number)
        } catch {
            throw ContextError.unreadablePullRequest(number: number, reason: String(errorDescription: error))
        }
    }

    private static func placeholder(
        for changes: GitChanges,
        base: String,
        named baseReference: String,
        repository: RepositoryName?,
        git: Git
    ) async throws -> PullRequest {
        let repositoryName = repository?.description ?? ""
        let headCommit = try await commit(changes.head, in: git)
        return .placeholder(
            for: changes,
            headCommit: headCommit,
            // The git user, who would open the pull request.
            author: try await git.setting("user.name") ?? headCommit.author.name,
            base: PullRequest.Branch(
                name: branchName(from: try await git.fullName(of: baseReference), typed: baseReference),
                commit: base,
                repository: repositoryName
            ),
            head: PullRequest.Branch(
                name: branchName(from: try await git.fullName(of: "HEAD"), typed: "HEAD"),
                commit: changes.head,
                repository: repositoryName
            )
        )
    }

    private static func repository(
        environment: [String: String],
        serverURL: URL,
        git: Git
    ) async throws -> RepositoryName? {
        if let value = environment["GITHUB_REPOSITORY"], !value.isEmpty {
            guard let repository = RepositoryName(value) else { throw ContextError.invalidRepository(value) }
            return repository
        }
        guard let host = serverURL.host, let remoteURL = try await git.url(ofRemote: "origin") else { return nil }
        return RepositoryName(remoteURL: remoteURL, host: host)
    }

    private static func commit(_ sha: String, in git: Git) async throws -> Commit {
        let log = try await git.output([
            "log", "--no-color", "--no-show-signature", "--encoding=UTF-8", "-1", "-z",
            "--format=\(Commit.logFormat)", sha, "--",
        ])
        guard let commit = Commit.commits(fromLog: log).first else {
            throw ContextError.gitFailed(arguments: ["log", "-1", sha], status: 0, message: "printed no commit")
        }
        return commit
    }

    /// A branch's name for the placeholder: `main` for `refs/heads/main` and
    /// `refs/remotes/origin/main`, and otherwise the revision as typed.
    private static func branchName(from fullName: String?, typed: String) -> String {
        guard let fullName else { return typed }
        if fullName.hasPrefix("refs/heads/") { return String(fullName.dropFirst("refs/heads/".count)) }
        guard fullName.hasPrefix("refs/remotes/") else { return typed }
        let remoteAndBranch = fullName.dropFirst("refs/remotes/".count)
        return remoteAndBranch.firstIndex(of: "/").map { String(remoteAndBranch[remoteAndBranch.index(after: $0)...]) }
            ?? String(remoteAndBranch)
    }
}
