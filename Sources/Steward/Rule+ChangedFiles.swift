import GitDiffKit

extension Rule {
    /// The most bytes one batch of `changedFiles` reads, a file's limit
    /// for each of its paths: the git reader holds them all at once.
    static let changedFilesBatchBytes = 64 << 20

    /// A rule that checks each file the pull request creates or changes
    /// whose head path matches `pattern`, given the file's bytes at the
    /// head and its changed lines.
    ///
    /// ```swift
    /// Rule.changedFiles("Licence header", in: "Sources/**/*.swift") { file in
    ///     file.contents.starts(with: Array("// SPDX-License-Identifier:".utf8))
    ///         ? [] : [.warning("Start with the licence header.", at: Location(path: file.path, line: 1))]
    /// }
    /// ```
    ///
    /// A file counts by its path at the head, which `excluded` matches
    /// too: a created, copied, modified or renamed file, never a deleted
    /// one. That includes a file the pull request only renames or changes
    /// the mode of, whose `changedLines` are empty. Each is checked once,
    /// in diff order, and the findings come in that order.
    ///
    /// Each file the rule skips is a finding of `skipKind` at the file, a
    /// warning by default, and a line in the run's log: a symbolic link or
    /// a submodule, which has no contents to check, and a file over
    /// `limit` bytes, whose finding says that raising `limit` has it
    /// checked. Git gives no mode for a link or a submodule it only
    /// renames, so a rename without one is skipped too when the head has
    /// no regular file there. No kind is silent, `.message` being the
    /// quietest: a file the rule should never check belongs in `excluded`.
    /// One that can't be read is a failure, whatever `skipKind` is, and
    /// isn't checked:
    ///
    /// - one the head doesn't have, or has as something other than the
    ///   regular file the diff says it is;
    /// - one whose name isn't UTF-8: a `String` can't name it, and its
    ///   name decoded could be another file's.
    ///
    /// Files are read a batch at a time, through the context's reader:
    /// the git reader runs the same two git processes for a batch as for
    /// one file, and one more `ls-tree` for each further 64 KiB of paths,
    /// and on macOS for each further 5,000 paths.
    /// A batch holds up to 64 MiB of files, at `limit` bytes per file, so
    /// 64 files at the default limit of 1 MiB; the git reader holds them
    /// twice while it parses them, so its peak is about twice that.
    ///
    /// What `check` throws is the rule's failure, as for any rule, and no
    /// file after it is checked; so is a malformed pattern.
    public static func changedFiles(
        _ name: String,
        in pattern: PathPattern,
        excluding excluded: PathPattern? = nil,
        limit: Int = FileContents.defaultLimit,
        reportingSkipsAs skipKind: Finding.Kind = .warning,
        _ check: @escaping @Sendable (ChangedFile) async throws -> [Finding]
    ) -> Rule {
        changedFiles(name, in: pattern, excluding: excluded, limit: limit, reportingSkipsAs: skipKind) { file, _ in
            try await check(file)
        }
    }

    /// A rule that checks each changed file as
    /// `changedFiles(_:in:excluding:limit:reportingSkipsAs:_:)` does, with
    /// a check that also writes to the run's log.
    ///
    /// The check's lines are the rule's, as `Rule(_:check:)`'s are, beside
    /// the ones naming the files the rule skipped: what it didn't check in
    /// a file, and why. Calling `evaluate`, as a test does, gives the check
    /// a log that writes nothing; StewardTesting's `Dangerfile.run(on:)`
    /// returns what a run logged.
    ///
    /// A file the check passes over itself is the check's to report, as the
    /// rule reports the files it skips: a line in the log is one a reviewer
    /// never sees, and the pull request may write the marker that skips it.
    ///
    /// ```swift
    /// Rule.changedFiles("Licence header", in: "Sources/**/*.swift") { file, log in
    ///     guard !file.contents.starts(with: Array("// Generated".utf8)) else {
    ///         log.write("Licence header: skipped \(file.path), a generated file")
    ///         return [.message("Not checked: a generated file.", at: Location(path: file.path))]
    ///     }
    ///     return file.contents.starts(with: Array("// SPDX-License-Identifier:".utf8))
    ///         ? [] : [.warning("Start with the licence header.", at: Location(path: file.path, line: 1))]
    /// }
    /// ```
    public static func changedFiles(
        _ name: String,
        in pattern: PathPattern,
        excluding excluded: PathPattern? = nil,
        limit: Int = FileContents.defaultLimit,
        reportingSkipsAs skipKind: Finding.Kind = .warning,
        _ check: @escaping @Sendable (ChangedFile, Log) async throws -> [Finding]
    ) -> Rule {
        Rule(name) { context, log in
            let matcher = try PathMatcher(pattern)
            let exclusion = try excluded.map { pattern throws(PathPatternError) in try PathMatcher(pattern) }
            let selected = context.git.diff.files.filter { file in
                guard file.header.change != .deleted, let path = file.header.newPath else { return false }
                return matcher.matches(path) && exclusion?.matches(path) != true
            }
            let skips = Skips(rule: name, kind: skipKind, log: log)
            let perBatch = max(1, changedFilesBatchBytes / max(1, limit))
            var findings: [Finding] = []
            // Imperative: each batch awaits its read, and each file its
            // check, in diff order.
            for start in stride(from: 0, to: selected.count, by: perBatch) {
                let batch = selected[start..<min(start + perBatch, selected.count)]
                let readable = batch.compactMap { file in path(toRead: file).map { (file: file, path: $0) } }
                let paths = readable.map(\.path)
                // A batch of links and submodules asks the reader for nothing.
                let read = paths.isEmpty ? [] : try await context.localRepository.contents(
                    ofFilesAt: paths,
                    in: context.git.head,
                    limit: limit
                )
                // A reader of a test's own may answer for fewer paths, or more.
                guard read.count == paths.count else {
                    return findings + [.failure("The reader gave \(read.count) answers for \(paths.count) paths.")]
                }
                var answers = zip(readable, read).makeIterator()
                for file in batch {
                    try Task.checkCancellation()
                    guard path(toRead: file) != nil, let answer = answers.next() else {
                        findings += [unreadFinding(for: file, skips: skips)].compactMap(\.self)
                        continue
                    }
                    let (entry, contents) = answer
                    guard case .bytes(let bytes) = contents else {
                        findings += [unreadFinding(for: contents, of: entry, limit: limit, skips: skips)]
                            .compactMap(\.self)
                        continue
                    }
                    let lines = GitChanges.addedLines(of: entry.file, into: LineRangeSet())
                    let changed = ChangedFile(path: entry.path, contents: bytes, changedLines: lines)
                    findings += try await check(changed, log)
                }
            }
            return findings
        }
    }

    /// How a `changedFiles` rule reports a file it skips: a line in the
    /// run's log, and a finding of `kind`.
    private struct Skips {
        let rule: String
        let kind: Finding.Kind
        let log: Log

        /// The finding for the file `name` names, skipped for `reason`,
        /// once the log says so; at `location`, which a name that isn't
        /// UTF-8 has none of. The rule's name is escaped, as a thrown
        /// rule's failure escapes it: it's a label, not Markdown. A file
        /// over the limit is checked once the limit is raised, which is
        /// what a source file usually needs, so its finding says that first.
        func finding(_ name: String, _ reason: String, at location: Location?, isOverLimit: Bool = false) -> Finding {
            log.write("\(rule): skipped \(name), \(reason)")
            let raising = isOverLimit ? "Raising the rule's `limit:` has it checked; a file" : "A file"
            return Finding(
                kind: kind,
                text: """
                    Rule “\(Markdown.escaped(rule))” skipped \(Markdown.codeSpan(name)), \(reason). \(raising) the \
                    rule should never check belongs in its `excluding:` pattern.
                    """,
                location: location
            )
        }
    }

    /// For a file read without its bytes: the skip of one over `limit`, or
    /// of a link or a submodule git only renames, or the failure for a
    /// file the head doesn't have as the regular file the diff says it is.
    private static func unreadFinding(
        for contents: FileContents,
        of entry: (file: DiffFile, path: String),
        limit: Int,
        skips: Skips
    ) -> Finding? {
        let path = entry.path
        let reason: String
        switch contents {
        case .bytes: return nil
        case .tooLarge(let size):
            return skips.finding(
                path,
                "\(size) bytes, over the limit of \(limit)",
                at: Location(path: path),
                isOverLimit: true
            )
        case .notRegularFile where entry.file.header.newMode == nil:
            // A link or a submodule git only renames: it writes no mode.
            return skips.finding(path, "not a regular file at the head", at: Location(path: path))
        case .noSuchFile: reason = "the diff lists it at the head, and the head has no such file"
        case .notRegularFile:
            reason = "the diff lists it at the head as a regular file, and the head has something else there"
        }
        return .failure("Couldn't check \(Markdown.codeSpan(path)): \(reason).", at: Location(path: path))
    }

    /// The path to read `file` by: its head path, when it's a regular file
    /// whose name is UTF-8.
    private static func path(toRead file: DiffFile) -> String? {
        guard file.header.newMode != .symlink, file.header.newMode != .gitlink,
              let path = file.header.newPath
        else { return nil }
        return String(validating: path.bytes, as: UTF8.self)
    }

    /// For a file that isn't read at all: the skip of a link or a
    /// submodule, or the failure for a name that isn't UTF-8.
    private static func unreadFinding(for file: DiffFile, skips: Skips) -> Finding? {
        guard path(toRead: file) == nil, let path = file.header.newPath else { return nil }
        let kind: String? = switch file.header.newMode {
        case .symlink?: "a symbolic link"
        case .gitlink?: "a submodule"
        default: nil
        }
        let name = String(validating: path.bytes, as: UTF8.self)
        if let kind {
            return skips.finding(name ?? quoted(path.bytes), kind, at: name.map { Location(path: $0) })
        }
        return .failure("""
            Couldn't check \(Markdown.codeSpan(quoted(path.bytes))): its name isn't UTF-8, so no `String` names \
            it, and read by its name decoded, it could be another file.
            """)
    }

    /// `bytes` as git quotes a name, without the quotes around it:
    /// printable ASCII as it is but for `"` and `\`, which a backslash
    /// escapes; `\a` through `\r` for the control characters C names; and
    /// any other byte as a backslash and three octal digits.
    static func quoted(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                return "\\" + String(UnicodeScalar(byte))
            case 0x07...0x0D:
                return "\\" + String(Array("abtnvfr")[Int(byte) - 0x07])
            case 0x20..<0x7F:
                return String(UnicodeScalar(byte))
            default:
                let octal = String(byte, radix: 8)
                return "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            }
        }
        .joined()
    }
}
