extension Context.FixtureError {
    /// A file given to the fixture: its path as given, and its contents.
    private typealias Given = (path: String, contents: [UInt8])

    /// The first place each of `files` disagrees with `diff`, in diff
    /// order: a file the diff deletes or renames away, one it makes a link
    /// or a submodule, or one that doesn't hold the diff's context and
    /// added lines where its hunk headers say.
    static func mismatches(between diff: Diff, and files: [String: [UInt8]]) -> [Mismatch] {
        // By bytes, as the reader matches paths: Swift's `==` takes a
        // name's precomposed and decomposed spellings for one.
        let given = Dictionary(files.map { (Array($0.key.utf8), Given($0.key, $0.value)) }) { $1 }
        // A path one entry deletes, another may create, as git writes a
        // file that becomes a symbolic link.
        let atHead = Set(diff.files.filter { $0.header.change != .deleted }.compactMap { $0.header.newPath?.bytes })
        return diff.files.flatMap { file in
            [leftBehind(by: file, in: given, atHead: atHead), disagreement(with: file, in: given)].compactMap(\.self)
        }
    }

    /// A given file that `file` deletes or renames away, when no other
    /// entry puts one back at its path.
    private static func leftBehind(by file: DiffFile, in given: [[UInt8]: Given], atHead: Set<[UInt8]>) -> Mismatch? {
        let header = file.header
        let change: String? = switch header.change {
        case .deleted: "deletes it"
        case .renamed: "renames it to \(header.newPath?.string ?? "another path")"
        default: nil
        }
        guard let change, let old = header.oldPath, !atHead.contains(old.bytes), let file = given[old.bytes] else {
            return nil
        }
        return Mismatch(path: file.path, line: nil, reason: "the diff \(change), so the head has no such file")
    }

    /// Where a given file at `file`'s new path disagrees with it.
    private static func disagreement(with file: DiffFile, in given: [[UInt8]: Given]) -> Mismatch? {
        let header = file.header
        guard header.change != .deleted, let new = header.newPath, let contents = given[new.bytes] else { return nil }
        // The reader holds regular files only; a real run's reports a link
        // or a submodule as one that isn't.
        guard header.newMode != .symlink, header.newMode != .gitlink else {
            return Mismatch(path: contents.path, line: nil, reason: """
                the diff makes it a \(header.newMode == .symlink ? "symbolic link" : "submodule"), which a run \
                reads as .notRegularFile; give the context a reader of its own for that
                """)
        }
        return firstDifference(between: file, and: contents.contents).map {
            Mismatch(path: contents.path, line: $0.line, reason: $0.reason)
        }
    }

    /// The first of `file`'s context and added lines that `contents`
    /// doesn't hold at its number, or whose end of file disagrees; where
    /// the diff shows the file's end, a line past it.
    private static func firstDifference(
        between file: DiffFile,
        and contents: [UInt8]
    ) -> (line: Int, reason: String)? {
        let endsWithNewline = contents.last == UInt8(ascii: "\n")
        let parts = contents.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        // A final line break ends the last line rather than start another.
        let lines = endsWithNewline || contents.isEmpty ? parts.dropLast() : parts[...]
        let differing = file.lines.lazy.compactMap { line -> (line: Int, reason: String)? in
            guard line.info.kind != .deletion, let number = line.info.newNumber else { return nil }
            guard number >= 1, number <= lines.count else {
                return (number, "the diff has a line \(number), and the file has \(count(lines.count))")
            }
            let actual = lines[lines.startIndex + number - 1]
            let expected = Array(line.content) + (line.info.endsWithCarriageReturn ? [UInt8(ascii: "\r")] : [])
            // A line the parser cut keeps only its start.
            let matches = line.info.isTruncated ? actual.starts(with: line.content) : actual.elementsEqual(expected)
            guard matches else {
                let shown = "the diff has \(quoted(expected)), and the file has \(quoted(Array(actual)))"
                return (number, shown + hint(expected, actual))
            }
            let isUnterminatedLast = number == lines.count && !endsWithNewline
            guard line.hasNoNewlineAtEnd == isUnterminatedLast else {
                return (number, line.hasNoNewlineAtEnd
                    ? "the diff says the file ends here without a newline, and the file doesn't"
                    : #"""
                    the file ends here without a newline, and the diff doesn't say so \#
                    (\ No newline at end of file)
                    """#)
            }
            return nil
        }
        .first
        guard differing == nil, let end = knownEnd(of: file), lines.count > end.line else { return differing }
        return (end.line + 1, "the diff \(end.how) with \(count(end.line)), and the file has \(lines.count)")
    }

    /// The head's last line of `file`, when the diff shows where the file
    /// ends without saying it ends there, and how it shows it.
    private static func knownEnd(of file: DiffFile) -> (line: Int, how: String)? {
        // A created file is all in the diff: one created empty has no lines.
        if file.header.change == .added, !file.header.isBinary {
            return (file.lines.count { $0.info.kind != .deletion }, "creates the file")
        }
        // Git marks an old last line that has no newline; once the diff
        // deletes it, nothing of the old file follows its hunk. A hunk that
        // leaves no lines starts at the line before it, as git writes it.
        guard let hunk = file.hunks.last(where: { hunk in
            hunk.lines.contains { $0.info.kind == .deletion && $0.hasNoNewlineAtEnd }
        }) else { return nil }
        let end = hunk.lines.last { $0.info.kind != .deletion }?.info.newNumber ?? hunk.header.newStart
        return (end, "deletes the file's old last line, leaving it")
    }

    /// `number` lines, in words.
    private static func count(_ number: Int) -> String {
        number == 1 ? "1 line" : "\(number) lines"
    }

    /// `bytes` as a Swift string literal, escapes and all, so whitespace
    /// shows; a long line is cut.
    private static func quoted(_ bytes: [UInt8]) -> String {
        let shown = String(decoding: bytes.prefix(100), as: UTF8.self).debugDescription
        return bytes.count > 100 ? shown + "…" : shown
    }

    /// Why two lines that look alike differ, when it's only their
    /// trailing whitespace: editors trim it, in a diff as in a file.
    private static func hint(_ expected: [UInt8], _ actual: some Collection<UInt8>) -> String {
        let isBlank = { (byte: UInt8) in byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") }
        let trimmedExpected = expected.reversed().drop(while: isBlank)
        let trimmedActual = actual.reversed().drop(while: isBlank)
        return trimmedExpected.elementsEqual(trimmedActual) ? " (they differ only in trailing whitespace)" : ""
    }
}
