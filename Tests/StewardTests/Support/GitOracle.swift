import Foundation
import GitDiffKit
@testable import Steward
import Testing

/// Checks a context's git data against what git itself says, through
/// commands Steward doesn't use: `--name-status`, `git apply --numstat` and
/// `--summary` on the patch, `rev-list`, `cat-file`, and the blobs of both
/// trees.
///
/// Runs git with the global and system configuration shut out, so what it
/// says doesn't depend on the machine.
struct GitOracle {
    /// The working tree, or the repository itself when bare.
    let directory: String

    func output(_ arguments: [String]) throws -> Data {
        try Subprocess.output(of: ["git", "-C", directory] + arguments, environment: TestRepository.environment)
    }

    func text(_ arguments: [String]) throws -> String {
        try String(decoding: output(arguments), as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// Records an issue for every way `changes` differs from git's account
    /// of the pull request from `base` to `changes.head`.
    func verify(_ changes: GitChanges, base: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let mergeBase = try text(["merge-base", base, changes.head])
        #expect(changes.mergeBase == mergeBase, sourceLocation: sourceLocation)
        try verifyFileLists(of: changes, sourceLocation: sourceLocation)
        try verifyPatch(of: changes, sourceLocation: sourceLocation)
        try verifyCommits(changes.commits, base: base, head: changes.head, sourceLocation: sourceLocation)
    }

    // MARK: - Files

    private func verifyFileLists(of changes: GitChanges, sourceLocation: SourceLocation) throws {
        let entries = try nameStatus(from: changes.mergeBase, to: changes.head)
        let created = entries.filter { $0.status == "A" }.map { $0.paths[0] }
        let deleted = entries.filter { $0.status == "D" }.map { $0.paths[0] }
        let modified = entries.filter { "MTR".contains($0.status) }.map { $0.paths[$0.paths.count - 1] }
        let renamed = entries.filter { $0.status == "R" }.map { GitChanges.Rename(from: $0.paths[0], to: $0.paths[1]) }
        #expect(changes.createdFiles == created, sourceLocation: sourceLocation)
        #expect(changes.deletedFiles == deleted, sourceLocation: sourceLocation)
        #expect(changes.modifiedFiles == modified, sourceLocation: sourceLocation)
        #expect(changes.renamedFiles == renamed, sourceLocation: sourceLocation)
        #expect(changes.diff.files.count == entries.count, sourceLocation: sourceLocation)
    }

    /// `git diff --name-status -z -M`: a status letter, then one path, or
    /// two for a rename or copy.
    func nameStatus(from old: String, to new: String) throws -> [(status: Character, paths: [String])] {
        let fields = try output(["diff", "--no-color", "--name-status", "-z", "-M", old, new, "--"])
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // Imperative: how many paths follow depends on the status.
        var entries: [(status: Character, paths: [String])] = []
        var index = 0
        while index < fields.count - 1, let status = fields[index].first {
            let pathCount = "RC".contains(status) ? 2 : 1
            entries.append((status, Array(fields[index + 1...index + pathCount])))
            index += 1 + pathCount
        }
        return entries
    }

    // MARK: - Patch

    private func verifyPatch(of changes: GitChanges, sourceLocation: SourceLocation) throws {
        let patch = try output(
            Git.diffConfiguration + ["diff"] + Git.diffOptions + ["--unified=3", changes.mergeBase, changes.head, "--"]
        )
        // Parsing loses nothing: the model renders back to git's bytes.
        #expect([UInt8](rendering: changes.diff) == Array(patch), sourceLocation: sourceLocation)
        #expect(changes.diff.damage.isEmpty, sourceLocation: sourceLocation)

        let patchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-tests-\(UUID().uuidString).patch")
        try patch.write(to: patchURL)
        defer { try? FileManager.default.removeItem(at: patchURL) }

        let counts = try output(["apply", "--numstat", "-z", patchURL.path])
        #expect(lineCounts(of: changes.diff) == Self.numstat(counts), sourceLocation: sourceLocation)

        let summary = try text(["apply", "--summary", patchURL.path])
        #expect(Self.summary(of: changes.diff) == Self.summary(summary), sourceLocation: sourceLocation)
    }

    /// Added and deleted lines per file, nil for a binary file, in the
    /// order of `git apply --numstat`.
    private func lineCounts(of diff: Diff) -> [[Int?]] {
        diff.files.map { file in
            guard !file.header.isBinary else { return [nil, nil] }
            return [
                file.lines.count { $0.info.kind == .addition },
                file.lines.count { $0.info.kind == .deletion },
            ]
        }
    }

    /// `git apply --numstat -z`: `added TAB deleted TAB path NUL`, or for a
    /// rename `added TAB deleted TAB NUL old NUL new NUL`; `-` for binary.
    private static func numstat(_ output: Data) -> [[Int?]] {
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // Imperative: a rename's record spans three fields.
        var counts: [[Int?]] = []
        var index = 0
        while index < fields.count - 1 {
            let columns = fields[index].split(separator: "\t", omittingEmptySubsequences: false)
            counts.append(columns.prefix(2).map { Int($0) })
            index += columns.count > 2 && columns[2].isEmpty ? 3 : 1
        }
        return counts
    }

    /// What `git apply --summary` says of each file, without paths (the
    /// name-status check covers those), sorted.
    private static func summary(of diff: Diff) -> [String] {
        diff.files.flatMap { file -> [String] in
            let header = file.header
            // Without its path: `apply` prints a renamed or copied file's
            // mode change on a line of its own.
            let modeChange = header.modeChanged
                ? ["mode change \(octal(header.oldMode)) => \(octal(header.newMode))"]
                : []
            switch header.change {
            case .added: return ["create mode \(octal(header.newMode))"]
            case .deleted: return ["delete mode \(octal(header.oldMode))"]
            case .renamed: return ["rename"] + modeChange
            case .copied: return ["copy"] + modeChange
            case .modified: return modeChange
            }
        }
        .sorted()
    }

    /// ` create mode 100644 path`, ` rename a => b (90%)`, ` mode change
    /// 100644 => 100755 path`, and so on, without the paths.
    private static func summary(_ output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.split(separator: " ").map(String.init) }
            .compactMap { words -> String? in
                switch words.first {
                case "create", "delete": words.prefix(3).joined(separator: " ")
                case "rename", "copy": words[0]
                case "mode": words.prefix(5).joined(separator: " ")
                default: nil
                }
            }
            .sorted()
    }

    /// As git prints modes: six octal digits.
    private static func octal(_ mode: FileMode?) -> String {
        mode.map { mode in
            let digits = String(mode.rawValue, radix: 8)
            return String(repeating: "0", count: max(0, 6 - digits.count)) + digits
        } ?? "?"
    }

    // MARK: - Commits

    private func verifyCommits(
        _ commits: [Commit],
        base: String,
        head: String,
        sourceLocation: SourceLocation
    ) throws {
        let shas = try text(["rev-list", "--reverse", "--topo-order", "\(base)..\(head)"])
            .split(separator: "\n").map(String.init)
        // Git's own order, and no commit before one of its parents.
        #expect(Set(commits.map(\.sha)) == Set(shas), sourceLocation: sourceLocation)
        let positions = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($1.sha, $0) })
        #expect(
            commits.enumerated().allSatisfy { index, commit in
                commit.parents.allSatisfy { positions[$0].map { $0 < index } ?? true }
            },
            sourceLocation: sourceLocation
        )
        let raw = try commits.map { try rawCommit($0.sha) }
        #expect(commits == raw, sourceLocation: sourceLocation)
    }

    /// A commit read from its raw object, `git cat-file commit`.
    func rawCommit(_ sha: String) throws -> Commit {
        let raw = try String(decoding: output(["cat-file", "commit", sha]), as: UTF8.self)
        let parts = raw.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        // Continuation lines of a multi-line header such as `gpgsig` start
        // with a space.
        let headers = parts[0].split(separator: "\n").filter { !$0.hasPrefix(" ") }
        func values(_ name: String) -> [String] {
            headers.filter { $0.hasPrefix("\(name) ") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let message = parts.count > 1 ? String(parts[1]) : ""
        let paragraphs = message.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: true)
        return Commit(
            sha: sha,
            parents: values("parent"),
            author: Self.signature(values("author").first ?? ""),
            committer: Self.signature(values("committer").first ?? ""),
            subject: paragraphs.first.map { $0.split(separator: "\n").joined(separator: " ") } ?? "",
            body: paragraphs.count > 1
                ? String(paragraphs[1].drop { $0.isNewline }.reversed().drop { $0.isNewline }.reversed())
                : ""
        )
    }

    /// `Name <email> 1700000000 +0000`.
    private static func signature(_ header: String) -> Commit.Signature {
        let name = header.prefix { $0 != "<" }.trimmingCharacters(in: .whitespaces)
        let email = header.drop { $0 != "<" }.dropFirst().prefix { $0 != ">" }
        let time = header.split(separator: " ").dropLast().last.flatMap { Int64($0) } ?? 0
        return Commit.Signature(name: name, email: String(email), date: Date(timeIntervalSince1970: TimeInterval(time)))
    }

    // MARK: - Line map

    /// Records an issue for every line of the built commit that `map` sends
    /// to a head line with other content, and for every file whose count of
    /// mapped lines isn't its lines minus the ones the built commit added.
    func verify(_ map: LineMap, head: String, built: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let entries = try nameStatus(from: head, to: built).filter { $0.status != "D" }
        let added = try addedLines(from: head, to: built)
        try entries.forEach { entry in
            let builtPath = entry.paths[entry.paths.count - 1]
            guard let builtLines = try lines(of: builtPath, at: built) else { return }
            let mapped = builtLines.indices.compactMap { index in
                map.headLocation(ofLine: index + 1, inFile: builtPath).map { (built: index, head: $0) }
            }
            #expect(
                mapped.count == builtLines.count - (added[builtPath] ?? 0),
                "\(builtPath): \(mapped.count) of \(builtLines.count) lines map",
                sourceLocation: sourceLocation
            )
            try mapped.forEach { pair in
                let headLines = try lines(of: pair.head.path, at: head) ?? []
                let headLine = pair.head.line.flatMap { headLines.indices.contains($0 - 1) ? headLines[$0 - 1] : nil }
                #expect(
                    headLine == builtLines[pair.built],
                    "\(builtPath):\(pair.built + 1) maps to \(pair.head.path):\(pair.head.line ?? 0)",
                    sourceLocation: sourceLocation
                )
            }
        }
    }

    /// Lines each built path adds, from `git diff --numstat -z -M`.
    private func addedLines(from old: String, to new: String) throws -> [String: Int] {
        let fields = try output(["diff", "--no-color", "--numstat", "-z", "-M", old, new, "--"])
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // Imperative: a rename's record spans three fields.
        var added: [String: Int] = [:]
        var index = 0
        while index < fields.count - 1 {
            let columns = fields[index].split(separator: "\t", omittingEmptySubsequences: false)
            let isRename = columns.count > 2 && columns[2].isEmpty
            let path = isRename ? fields[index + 2] : String(columns.count > 2 ? columns[2] : "")
            added[path] = Int(columns[0])
            index += isRename ? 3 : 1
        }
        return added
    }

    /// The lines of the file at `path` in `commit`, nil for a binary file or
    /// one that isn't there.
    func lines(of path: String, at commit: String) throws -> [Data]? {
        let blob = try output(["cat-file", "-p", "\(commit):\(path)"])
        guard !blob.contains(0) else { return nil }
        var lines = blob.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.map { Data($0) }
    }
}
