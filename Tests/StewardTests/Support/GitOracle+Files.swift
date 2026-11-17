import Foundation

extension GitOracle {
    /// What `git show <commit>:<path>` prints, byte for byte, or nil when
    /// the commit has no such path.
    ///
    /// The path reaches git through `xargs -0`, byte for byte: as an
    /// argument of `Process`, macOS would decompose its accented letters.
    /// Git is told not to compose them back, and to take the argument as
    /// a revision, which it would take for a pattern were it to hold `*`.
    func show(_ path: String, at commit: String) throws -> [UInt8]? {
        let object = Data("\(commit):\(path)".utf8) + [0]
        // `show` says "bad revision" for a missing path and a missing
        // commit alike; `cat-file -e` tells them apart.
        let exists = try git(["cat-file", "-e"], input: object)
        guard exists.status == 0 else {
            guard exists.error.hasPrefix("fatal: path '") else {
                throw FixtureError("git cat-file -e \(commit):\(path) failed with \(exists.status): \(exists.error)")
            }
            return nil
        }
        let shown = try git(["show", "--no-textconv"], input: object + Data("--".utf8) + [0])
        guard shown.status == 0 else {
            throw FixtureError("git show \(commit):\(path) failed with \(shown.status): \(shown.error)")
        }
        return Array(shown.output)
    }

    /// The mode `git ls-tree` gives `path` in `commit`: `120000` for a
    /// symbolic link, `160000` for a submodule.
    func mode(of path: String, at commit: String) throws -> String {
        String(try text(["ls-tree", commit, "--", path]).prefix { $0 != " " })
    }

    /// Runs git with `arguments`, then the NUL-separated arguments in
    /// `input`, passed on byte for byte.
    private func git(_ arguments: [String], input: Data) throws -> Subprocess.Result {
        try Subprocess.run(
            ["xargs", "-0", "git", "-C", directory, "-c", "core.precomposeUnicode=false"] + arguments,
            environment: TestRepository.environment,
            input: input
        )
    }
}

extension GitOracle {
    /// Each path of `commit`'s tree, files and directories alike, with
    /// its mode, as `git ls-tree -r -t` lists them: UTF-8 names only, as
    /// a `String` names no other.
    func modes(at commit: String) throws -> [String: String] {
        try output(["ls-tree", "-r", "-t", "-z", "--full-tree", commit])
            .split(separator: 0)
            .reduce(into: [:]) { modes, record in
                guard let tab = record.firstIndex(of: UInt8(ascii: "\t")),
                      let path = String(validating: record[record.index(after: tab)...], as: UTF8.self)
                else { return }
                modes[path] = String(decoding: record.prefix { $0 != UInt8(ascii: " ") }, as: UTF8.self)
            }
    }
}
