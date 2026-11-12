extension GitChanges {
    /// The changes limited to the files `pattern` matches: the same
    /// commits, merge base and head, and the diff's files that match, so
    /// every file list and `file(at:)` read only those.
    ///
    /// A file matches by either path: a deleted file by its old one, and a
    /// renamed file, which stays one entry with both paths, by either. A
    /// copy matches by its new path alone, as the file it creates. The
    /// diff keeps its damage reports, which may concern any file.
    ///
    /// ```swift
    /// Rule("MBK strings") { context in
    ///     try context.git.changes(matching: "mbk/**/*.xcstrings").modifiedFiles.map { path in
    ///         .message("Check the translations of \(Markdown.codeSpan(path)).", at: Location(path: path))
    ///     }
    /// }
    /// ```
    ///
    /// Throws when `pattern` is malformed, naming it and what's wrong.
    public func changes(matching pattern: PathPattern) throws -> GitChanges {
        let matcher = try PathMatcher(pattern)
        var changes = self
        changes.diff.files = diff.files.filter(matcher.matches)
        return changes
    }
}
