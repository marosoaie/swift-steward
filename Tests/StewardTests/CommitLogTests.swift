import Foundation
@testable import Steward
import Testing

@Suite("Commits read from git log's NUL-separated fields")
struct CommitLogTests {
    /// `git log -z` output for commits given as their ten fields: each
    /// field ends with a NUL, the last one standing for `-z`'s terminator.
    private func log(_ commits: [[String]]) -> [UInt8] {
        commits.flatMap { fields in fields.flatMap { Array($0.utf8) + [0] } }
    }

    private let sha = String(repeating: "a", count: 40)
    private let parent = String(repeating: "b", count: 40)
    private let otherParent = String(repeating: "c", count: 40)

    @Test("every field lands where it belongs, and dates are seconds since the epoch")
    func fields() {
        let commits = Commit.commits(fromLog: log([
            [sha, parent, "Ada", "ada@example.com", "1700000000", "Charles", "charles@example.com", "1700000060",
             "Add the thing", "Because.\n\nMore.\n\n"],
        ]))
        #expect(commits == [
            Commit(
                sha: sha,
                parents: [parent],
                author: .init(name: "Ada", email: "ada@example.com", date: Date(timeIntervalSince1970: 1_700_000_000)),
                committer: .init(
                    name: "Charles",
                    email: "charles@example.com",
                    date: Date(timeIntervalSince1970: 1_700_000_060)
                ),
                subject: "Add the thing",
                body: "Because.\n\nMore."
            ),
        ])
    }

    @Test("a root commit has no parents, and a merge has two")
    func parents() {
        let commits = Commit.commits(fromLog: log([
            [parent, "", "A", "a@x", "1", "A", "a@x", "1", "Root", ""],
            [sha, "\(parent) \(otherParent)", "A", "a@x", "2", "A", "a@x", "2", "Merge", "\n"],
        ]))
        #expect(commits.map(\.parents) == [[], [parent, otherParent]])
        #expect(commits.map(\.body) == ["", ""])
    }

    @Test("a timestamp git couldn't print reads as the epoch")
    func unreadableTimestamp() {
        let commits = Commit.commits(fromLog: log([
            [sha, "", "A", "a@x", "", "A", "a@x", "99999999999999999999999", "Subject", ""],
        ]))
        #expect(commits.first?.author.date == Date(timeIntervalSince1970: 0))
        #expect(commits.first?.committer.date == Date(timeIntervalSince1970: 0))
    }

    @Test("no output reads as no commits, and a commit cut short is dropped")
    func truncated() {
        #expect(Commit.commits(fromLog: []).isEmpty)
        var output = log([[sha, "", "A", "a@x", "1", "A", "a@x", "1", "Whole", ""]])
        output += Array("\(parent)\0\0A\0a@x\0".utf8)
        #expect(Commit.commits(fromLog: output).map(\.subject) == ["Whole"])
    }

    @Test("bytes that aren't UTF-8 decode lossily rather than dropping the commit")
    func invalidUTF8() {
        var output = log([[sha, "", "A", "a@x", "1", "A", "a@x", "1"]])
        output += [0x43, 0x61, 0x66, 0xE9, 0] + [0]
        #expect(Commit.commits(fromLog: output).map(\.subject) == ["Caf\u{FFFD}"])
    }
}
