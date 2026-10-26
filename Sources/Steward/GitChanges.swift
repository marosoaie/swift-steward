import GitDiffKit

/// A pull request's changes as git sees them: the diff from the merge base
/// to the head commit, and the commits in between.
///
/// The diff is the three-dot diff `base...head` that GitHub's Files changed
/// tab shows, so a base branch that moves after the event doesn't change it.
/// The file lists decode paths lossily to `String`s (see `DiffPath.string`);
/// a rule that must tell apart two paths that decode alike reads the
/// `DiffPath`s in `diff`.
public struct GitChanges: Sendable, Equatable {
    /// A file the pull request moves, with or without editing it.
    public struct Rename: Sendable, Hashable {
        /// The path in the merge base.
        public var from: String
        /// The path in the head commit.
        public var to: String

        /// Creates a rename from its two paths.
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// GitDiffKit's full model of the diff from `mergeBase` to `head`.
    ///
    /// Renames are detected (`-M`), copies aren't, so a copied file shows up
    /// as a created one.
    public var diff: Diff
    /// The commits the head has and the base doesn't, oldest first.
    public var commits: [Commit]
    /// The SHA of the commit where the diff starts: the merge base of the
    /// pull request's base and head commits.
    public var mergeBase: String
    /// The SHA of the pull request's head commit, where the diff ends.
    public var head: String

    /// Creates the changes from their parts.
    public init(diff: Diff, commits: [Commit], mergeBase: String, head: String) {
        self.diff = diff
        self.commits = commits
        self.mergeBase = mergeBase
        self.head = head
    }

    /// The paths of the files the pull request creates, in diff order.
    /// A copy counts as created, under its new path.
    public var createdFiles: [String] {
        diff.files.compactMap { file in
            switch file.header.change {
            case .added, .copied: file.header.newPath?.string
            case .deleted, .modified, .renamed: nil
            }
        }
    }

    /// The paths of the files the pull request deletes, in diff order.
    public var deletedFiles: [String] {
        diff.files.compactMap { file in
            file.header.change == .deleted ? file.header.oldPath?.string : nil
        }
    }

    /// The paths of the files that exist on both sides, in diff order:
    /// edited, renamed (under the new path), or with only their mode
    /// changed. This is what the Files changed tab shows as changed.
    public var modifiedFiles: [String] {
        diff.files.compactMap { file in
            switch file.header.change {
            case .modified, .renamed: file.header.newPath?.string
            case .added, .copied, .deleted: nil
            }
        }
    }

    /// The files the pull request moves, in diff order.
    public var renamedFiles: [Rename] {
        diff.files.compactMap { file in
            guard case .renamed = file.header.change,
                  let from = file.header.oldPath, let to = file.header.newPath
            else { return nil }
            return Rename(from: from.string, to: to.string)
        }
    }

    /// The diff of the file at `path` in the head commit, or, when no file
    /// is there, of the file that was at `path` in the merge base: a
    /// deleted file, or a renamed one under its old name.
    public func file(at path: String) -> DiffFile? {
        diff.files.first { $0.header.newPath?.string == path }
            ?? diff.files.first { $0.header.oldPath?.string == path }
    }
}
