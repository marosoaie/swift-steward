/// A pull request's metadata, as its host reports it.
public struct PullRequest: Sendable, Hashable {
    /// Whether a pull request is still open, and how it ended.
    public enum State: Sendable, Hashable {
        /// Open, drafts included.
        case open
        /// Closed without merging.
        case closed
        /// Merged, and therefore closed.
        case merged
    }

    /// One end of a pull request: the branch it merges from or into.
    public struct Branch: Sendable, Hashable {
        /// The branch name, without `refs/heads/`.
        public var name: String
        /// The commit the branch pointed to when the host last looked.
        public var commit: String
        /// The repository the branch lives in, as `owner/name`.
        public var repository: String

        /// Creates a branch from its name, commit, and repository.
        public init(name: String, commit: String, repository: String) {
            self.name = name
            self.commit = commit
            self.repository = repository
        }
    }

    /// The number the host shows, unique within the repository.
    public var number: Int
    /// The title.
    public var title: String
    /// The description, as the author wrote it; empty when there is none.
    public var body: String
    /// The author's login.
    public var author: String
    /// Whether it's open, closed, or merged.
    public var state: State
    /// Whether it's marked as a draft.
    public var isDraft: Bool
    /// The branch it merges into.
    public var base: Branch
    /// The branch it merges from.
    public var head: Branch
    /// The names of its labels.
    public var labels: [String]
    /// Its page on the host's website.
    public var webURL: String
    /// Lines added across the whole pull request.
    public var additions: Int
    /// Lines deleted across the whole pull request.
    public var deletions: Int
    /// Files the pull request changes.
    public var changedFiles: Int
    /// Commits on the head branch that the base doesn't have.
    public var commits: Int

    /// Creates a pull request from all of its metadata.
    public init(
        number: Int,
        title: String,
        body: String,
        author: String,
        state: State,
        isDraft: Bool,
        base: Branch,
        head: Branch,
        labels: [String],
        webURL: String,
        additions: Int,
        deletions: Int,
        changedFiles: Int,
        commits: Int
    ) {
        self.number = number
        self.title = title
        self.body = body
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.base = base
        self.head = head
        self.labels = labels
        self.webURL = webURL
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.commits = commits
    }

    /// Whether the head branch lives in another repository than the base,
    /// usually a fork.
    public var isFromFork: Bool {
        head.repository != base.repository
    }
}
