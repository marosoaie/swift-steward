import Foundation
@testable import Steward
import Testing

extension GitOracle {
    /// Records an issue for every way `commits` differs from git's own
    /// list of the commits from `base` to `head`, and from their raw objects.
    func verifyCommits(
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

    /// A commit read from its raw object, `git cat-file commit`, in UTF-8.
    func rawCommit(_ sha: String) throws -> Commit {
        let raw = try Self.utf8(commit: output(["cat-file", "commit", sha]))
        let parts = raw.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        // Continuation lines of a multi-line header such as `gpgsig` start
        // with a space.
        let headers = parts[0].split(separator: "\n").filter { !$0.hasPrefix(" ") }
        func values(_ name: String) -> [String] {
            headers.filter { $0.hasPrefix("\(name) ") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let message = Self.subjectAndBody(of: parts.count > 1 ? Array(parts[1].utf8) : [])
        return Commit(
            sha: sha,
            parents: values("parent"),
            author: Self.signature(values("author").first ?? ""),
            committer: Self.signature(values("committer").first ?? ""),
            subject: message.subject,
            body: String(message.body.reversed().drop { $0.isNewline }.reversed())
        )
    }

    /// A message's subject and body as git's `%s` and `%b` read them. A
    /// line of whitespace only ends a paragraph, whitespace being what
    /// git's own `isspace` counts (space, tab, CR, LF); the subject is the
    /// first paragraph, each line without its trailing whitespace, joined
    /// with spaces. In bytes: `\r\n` is one `Character`.
    private static func subjectAndBody(of message: [UInt8]) -> (subject: String, body: String) {
        let isSpace: (UInt8) -> Bool = { [0x20, 0x09, 0x0D, 0x0A].contains($0) }
        let isBlank: (ArraySlice<UInt8>) -> Bool = { $0.allSatisfy(isSpace) }
        let fromSubject = message.split(separator: 0x0A, omittingEmptySubsequences: false).drop(while: isBlank)
        let subjectLines = fromSubject.prefix { !isBlank($0) }
        let bodyLines = fromSubject.dropFirst(subjectLines.count).drop(while: isBlank)
        return (
            subject: subjectLines
                .map { String(decoding: Array($0.reversed().drop(while: isSpace).reversed()), as: UTF8.self) }
                .joined(separator: " "),
            body: String(decoding: Array(bodyLines.joined(separator: [0x0A])), as: UTF8.self)
        )
    }

    /// A raw commit in UTF-8, as `git log --encoding=UTF-8` reads it: one
    /// whose `encoding` header names another goes through iconv, as git's
    /// own conversion does, and stays as it is when iconv can't convert it.
    private static func utf8(commit: Data) throws -> String {
        let raw = String(decoding: commit, as: UTF8.self)
        let headers = raw.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "\n")
        guard let encoding = headers.first(where: { $0.hasPrefix("encoding ") })?.dropFirst("encoding ".count),
              !["utf-8", "utf8"].contains(encoding.lowercased())
        else { return raw }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-tests-\(UUID().uuidString).commit")
        try commit.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let converted = try? Subprocess.output(of: ["iconv", "-f", String(encoding), "-t", "UTF-8", file.path])
        return converted.map { String(decoding: $0, as: UTF8.self) } ?? raw
    }

    /// `Name <email> 1700000000 +0000`.
    private static func signature(_ header: String) -> Commit.Signature {
        let name = header.prefix { $0 != "<" }.trimmingCharacters(in: .whitespaces)
        let email = header.drop { $0 != "<" }.dropFirst().prefix { $0 != ">" }
        let time = header.split(separator: " ").dropLast().last.flatMap { Int64($0) } ?? 0
        return Commit.Signature(name: name, email: String(email), date: Date(timeIntervalSince1970: TimeInterval(time)))
    }
}
