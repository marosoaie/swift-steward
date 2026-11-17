extension GitRepositoryFiles {
    /// One record of `git ls-tree -z --long`:
    /// `<mode> SP <type> SP <object> SP <size> TAB <path> NUL`, the size
    /// padded with spaces, or `-` for a directory or a submodule.
    struct TreeEntry: Sendable, Hashable {
        /// Six octal digits: `100644` or `100755` for a regular file,
        /// `120000` for a symbolic link, `160000` for a submodule,
        /// `040000` for a directory.
        var mode: String
        var type: String
        var object: String
        var size: Int?
        /// The path from the repository's root, byte for byte.
        var path: [UInt8]

        /// The size of a regular file, or nil for anything else. Read
        /// from the mode, which git sets apart from the object's type, so
        /// a symbolic link, a blob whose mode is `120000`, isn't one.
        var regularFileSize: Int? {
            mode.hasPrefix("100") && type == "blob" ? size : nil
        }

        /// The record's entry, or nil when it isn't one `ls-tree` writes.
        init?(record: ArraySlice<UInt8>) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else { return nil }
            let fields = record[..<tab].split(separator: UInt8(ascii: " "))
            guard fields.count == 4, fields[2].count == 40 || fields[2].count == 64,
                  fields[2].allSatisfy(Self.isHexDigit)
            else { return nil }
            mode = String(decoding: fields[0], as: UTF8.self)
            type = String(decoding: fields[1], as: UTF8.self)
            object = String(decoding: fields[2], as: UTF8.self)
            size = GitRepositoryFiles.decimal(fields[3])
            path = Array(record[record.index(after: tab)...])
        }

        /// The entries of `ls-tree -z --long` output, skipping any record
        /// that isn't one.
        static func entries(in output: [UInt8]) -> [TreeEntry] {
            output.split(separator: 0).compactMap(TreeEntry.init(record:))
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// The tree entries of `commit` whose paths are among `names`, by
    /// path.
    ///
    /// Paths are taken literally (`--literal-pathspecs`): `a*.swift` is
    /// the file of that name, and `:(glob)` is no magic. `--full-tree`
    /// makes them the root's, wherever the checkout is, and `-t` lists a
    /// directory even when another path leads into it. Entries are
    /// matched to `names` as bytes, since git answers `./a` with `a` and
    /// `dir/` with what's in it, and Swift's `==` takes a name's
    /// precomposed and decomposed spellings for one.
    ///
    /// On macOS, `Process` decomposes every argument's accented letters,
    /// so git turns them back (`core.precomposeUnicode`, which Linux's
    /// git ignores): a name stored precomposed, as git stores names on
    /// macOS, is found; one stored decomposed isn't, there.
    func entries(
        named names: Set<[UInt8]>,
        in commit: String,
        pathBytesPerCall: Int
    ) async throws -> [[UInt8]: TreeEntry] {
        var entries: [[UInt8]: TreeEntry] = [:]
        // Imperative: each call awaits git, which the combinators can't.
        for paths in Self.calls(for: names.sorted { $0.lexicographicallyPrecedes($1) }, upTo: pathBytesPerCall) {
            let arguments = [
                "--literal-pathspecs", "-c", "core.precomposeUnicode=true",
                "ls-tree", "-z", "-t", "--long", "--full-tree", "--end-of-options", "\(commit)^{commit}", "--",
            ] + paths.map { String(decoding: $0, as: UTF8.self) }
            let output = try await git.output(arguments)
            TreeEntry.entries(in: output)
                .filter { names.contains($0.path) }
                .forEach { entries[$0.path] = $0 }
        }
        return entries
    }

    /// `paths` split into calls of at most `bytes` bytes of paths each,
    /// but for a longer path, which has a call of its own.
    static func calls(for paths: [[UInt8]], upTo bytes: Int) -> [[[UInt8]]] {
        paths.reduce(into: (calls: [[[UInt8]]](), bytes: 0)) { state, path in
            // One more for the separator the arguments come with.
            let size = path.count + 1
            if !state.calls.isEmpty, size <= bytes - state.bytes {
                state.calls[state.calls.count - 1].append(path)
                state.bytes += size
            } else {
                state.calls.append([path])
                state.bytes = size
            }
        }
        .calls
    }
}
