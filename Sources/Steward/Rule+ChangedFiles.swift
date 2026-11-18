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
    /// in diff order.
    ///
    /// The run's log names each file that's skipped: a symbolic link or a
    /// submodule, which has no contents to check, and a file over `limit`
    /// bytes. Git gives no mode for a link or a submodule it only renames,
    /// so a rename without one is skipped too when the head has no regular
    /// file there. One that can't be read is a failure, and isn't checked:
    ///
    /// - one the head doesn't have, or has as something other than the
    ///   regular file the diff says it is;
    /// - one whose name isn't UTF-8: a `String` can't name it, and its
    ///   name decoded could be another file's.
    ///
    /// Files are read a batch at a time, through the context's reader:
    /// the git reader runs the same two git processes for a batch as for
    /// one file, and one more `ls-tree` for each further 64 KiB of paths.
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
        _ check: @escaping @Sendable (ChangedFile) async throws -> [Finding]
    ) -> Rule {
        Rule(name) { context, log in
            let matcher = try PathMatcher(pattern)
            let exclusion = try excluded.map { pattern throws(PathPatternError) in try PathMatcher(pattern) }
            let selected = context.git.diff.files.filter { file in
                guard file.header.change != .deleted, let path = file.header.newPath else { return false }
                return matcher.matches(path) && exclusion?.matches(path) != true
            }
            var findings = selected.compactMap { unreadFinding(for: $0, name: name, log: log) }
            let readable = selected.compactMap { file in path(toRead: file).map { (file: file, path: $0) } }
            let perBatch = max(1, changedFilesBatchBytes / max(1, limit))
            // Imperative: each batch awaits its read, and each file its check.
            for start in stride(from: 0, to: readable.count, by: perBatch) {
                let batch = readable[start..<min(start + perBatch, readable.count)]
                let paths = batch.map(\.path)
                let read = try await context.localRepository.contents(
                    ofFilesAt: paths,
                    in: context.git.head,
                    limit: limit
                )
                // A reader of a test's own may answer for fewer paths, or more.
                guard read.count == paths.count else {
                    return findings + [.failure("The reader gave \(read.count) answers for \(paths.count) paths.")]
                }
                for (entry, contents) in zip(batch, read) {
                    try Task.checkCancellation()
                    guard case .bytes(let bytes) = contents else {
                        findings += [unreadFinding(for: contents, of: entry, name: name, limit: limit, log: log)]
                            .compactMap(\.self)
                        continue
                    }
                    let lines = GitChanges.addedLines(of: entry.file, into: LineRangeSet())
                    findings += try await check(ChangedFile(path: entry.path, contents: bytes, changedLines: lines))
                }
            }
            return findings
        }
    }

    /// For a file read without its bytes: nil once the log says it was
    /// skipped, or the failure for a file the head doesn't have as the
    /// regular file the diff says it is.
    private static func unreadFinding(
        for contents: FileContents,
        of entry: (file: DiffFile, path: String),
        name: String,
        limit: Int,
        log: Log
    ) -> Finding? {
        let path = entry.path
        let reason: String
        switch contents {
        case .bytes: return nil
        case .tooLarge(let size):
            log.write("\(name): skipped \(path), \(size) bytes, over the limit of \(limit)")
            return nil
        case .notRegularFile where entry.file.header.newMode == nil:
            // A link or a submodule git only renames: it writes no mode.
            log.write("\(name): skipped \(path), not a regular file at the head")
            return nil
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

    /// For a file that isn't read at all: nil once the log says a link or
    /// a submodule was skipped, or the failure for a name that isn't
    /// UTF-8.
    private static func unreadFinding(for file: DiffFile, name: String, log: Log) -> Finding? {
        guard path(toRead: file) == nil, let path = file.header.newPath else { return nil }
        let kind: String? = switch file.header.newMode {
        case .symlink?: "a symbolic link"
        case .gitlink?: "a submodule"
        default: nil
        }
        if let kind {
            log.write("\(name): skipped \(path.string), \(kind)")
            return nil
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
