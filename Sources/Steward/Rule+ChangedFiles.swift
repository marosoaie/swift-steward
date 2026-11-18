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
    /// bytes. One that can't be read is a failure, and isn't checked:
    ///
    /// - one the head doesn't have, or has as something other than a
    ///   regular file, though the diff lists it;
    /// - one whose name isn't UTF-8: a `String` can't name it, and its
    ///   name decoded could be another file's.
    ///
    /// Files are read a batch at a time, through the context's reader:
    /// for the git reader, two processes per batch rather than three per
    /// file. A batch holds up to 64 MiB, at `limit` bytes per file, so 64
    /// files at the default limit of 1 MiB.
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
                let read = try await context.files.contents(ofFilesAt: paths, in: context.git.head, limit: limit)
                // A reader of a test's own may answer for fewer paths, or more.
                guard read.count == paths.count else {
                    return findings + [.failure("The reader gave \(read.count) answers for \(paths.count) paths.")]
                }
                for (entry, contents) in zip(batch, read) {
                    try Task.checkCancellation()
                    guard case .bytes(let bytes) = contents else {
                        findings += [unreadFinding(for: contents, at: entry.path, name: name, limit: limit, log: log)]
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
    /// over the limit, or the failure for a file the head doesn't have as
    /// a regular file.
    private static func unreadFinding(
        for contents: FileContents,
        at path: String,
        name: String,
        limit: Int,
        log: Log
    ) -> Finding? {
        let reason: String
        switch contents {
        case .bytes: return nil
        case .tooLarge(let size):
            log.write("\(name): skipped \(path), \(size) bytes, over the limit of \(limit)")
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

    /// `bytes` as git quotes a name: printable ASCII as it is, and any
    /// other byte, and a backslash, as a backslash and three octal digits.
    private static func quoted(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            guard byte < 0x20 || byte >= 0x7F || byte == UInt8(ascii: "\\") else { return String(UnicodeScalar(byte)) }
            let octal = String(byte, radix: 8)
            return "\\" + String(repeating: "0", count: 3 - octal.count) + octal
        }
        .joined()
    }
}
