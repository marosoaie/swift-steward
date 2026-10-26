import Foundation
import GitDiffKit
@testable import Steward
import Testing

/// Checks a context's git data against what git itself says, through
/// commands Steward doesn't use: `--raw`, `git apply --numstat` and
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
        let entries = try rawStatus(from: changes.mergeBase, to: changes.head)
        // A type change (T: a file became a symlink, say) is one entry here
        // but two patches, a deletion and a creation.
        let created = entries.filter { "AT".contains($0.status) }.map { $0.paths[0] }
        let deleted = entries.filter { "DT".contains($0.status) }.map { $0.paths[0] }
        let modified = entries.filter { "MR".contains($0.status) }.map { $0.paths[$0.paths.count - 1] }
        let renamed = entries.filter { $0.status == "R" }.map { GitChanges.Rename(from: $0.paths[0], to: $0.paths[1]) }
        let typeChanges = entries.count { $0.status == "T" }
        #expect(changes.createdFiles == created, sourceLocation: sourceLocation)
        #expect(changes.deletedFiles == deleted, sourceLocation: sourceLocation)
        #expect(changes.modifiedFiles == modified, sourceLocation: sourceLocation)
        #expect(changes.renamedFiles == renamed, sourceLocation: sourceLocation)
        #expect(changes.diff.files.count == entries.count + typeChanges, sourceLocation: sourceLocation)
    }

    /// A file in `git diff --raw` output.
    struct RawEntry {
        let status: Character
        /// Six octal digits: `160000` for a submodule.
        let newMode: String
        /// One path, or the old and new for a rename or copy.
        let paths: [String]
    }

    /// `git diff --raw -z -M`: both modes, both blobs, and a status letter,
    /// then one path, or two for a rename or copy.
    func rawStatus(from old: String, to new: String) throws -> [RawEntry] {
        let fields = try output(["diff", "--no-color", "--raw", "-z", "-M", old, new, "--"])
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // Imperative: how many paths follow depends on the status.
        var entries: [RawEntry] = []
        var index = 0
        while index < fields.count - 1 {
            // `:100644 100644 <blob> <blob> M`, the status with a score for
            // a rename or copy.
            let words = fields[index].split(separator: " ")
            guard words.count == 5, let status = words[4].first else { break }
            let pathCount = "RC".contains(status) ? 2 : 1
            let paths = Array(fields[index + 1...index + pathCount])
            entries.append(RawEntry(status: status, newMode: String(words[1]), paths: paths))
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
            let columns = Self.numstatColumns(fields[index])
            counts.append(columns.prefix(2).map { Int($0) })
            index += columns.count > 2 && columns[2].isEmpty ? 3 : 1
        }
        return counts
    }

    /// A `--numstat -z` record's added and deleted counts and its path,
    /// empty for a rename, whose paths follow. Split twice only: with `-z`
    /// git writes a path's tabs as they are.
    private static func numstatColumns(_ record: String) -> [Substring] {
        record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
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

    // MARK: - Line map

    /// Records an issue for every line of the built commit that `map` sends
    /// to a head line with other content, and for every file whose count of
    /// mapped lines isn't its lines minus the ones the built commit added.
    func verify(_ map: LineMap, head: String, built: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        // A gitlink names a commit of its submodule, which this repository
        // needn't have.
        let entries = try rawStatus(from: head, to: built).filter { $0.status != "D" && $0.newMode != "160000" }
        let (added, binary) = try addedLines(from: head, to: built)
        try entries.forEach { entry in
            let builtPath = entry.paths[entry.paths.count - 1]
            guard let builtLines = try lines(of: builtPath, at: built) else { return }
            let mapped = builtLines.indices.compactMap { index in
                map.headLocation(ofLine: index + 1, inFile: builtPath).map { (built: index, head: $0) }
            }
            // A file a `-diff` attribute marks binary has no NUL to tell by,
            // and no line of a binary file maps.
            guard !binary.contains(builtPath) else {
                #expect(mapped.isEmpty, "\(builtPath): binary, but lines map", sourceLocation: sourceLocation)
                return
            }
            #expect(
                mapped.count == builtLines.count - (added[builtPath] ?? 0),
                "\(builtPath): \(mapped.count) of \(builtLines.count) lines map",
                sourceLocation: sourceLocation
            )
            // One read per head file, not per line: a subprocess each.
            let headFiles = try Dictionary(
                uniqueKeysWithValues: Set(mapped.map(\.head.path)).map { ($0, try lines(of: $0, at: head) ?? []) }
            )
            mapped.forEach { pair in
                let headLines = headFiles[pair.head.path] ?? []
                let headLine = pair.head.line.flatMap { headLines.indices.contains($0 - 1) ? headLines[$0 - 1] : nil }
                #expect(
                    headLine == builtLines[pair.built],
                    "\(builtPath):\(pair.built + 1) maps to \(pair.head.path):\(pair.head.line ?? 0)",
                    sourceLocation: sourceLocation
                )
            }
        }
    }

    /// Lines each built path adds, from `git diff --numstat -z -M`, and the
    /// paths git diffs as binary, whose counts are `-`.
    private func addedLines(from old: String, to new: String) throws -> (added: [String: Int], binary: Set<String>) {
        let fields = try output(["diff", "--no-color", "--numstat", "-z", "-M", old, new, "--"])
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // Imperative: a rename's record spans three fields.
        var added: [String: Int] = [:]
        var binary: Set<String> = []
        var index = 0
        while index < fields.count - 1 {
            let columns = Self.numstatColumns(fields[index])
            let isRename = columns.count > 2 && columns[2].isEmpty
            let path = isRename ? fields[index + 2] : String(columns.count > 2 ? columns[2] : "")
            if let count = Int(columns[0]) {
                added[path] = count
            } else {
                binary.insert(path)
            }
            index += isRename ? 3 : 1
        }
        return (added, binary)
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
