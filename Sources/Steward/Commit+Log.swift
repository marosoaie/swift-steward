import Foundation

extension Commit {
    /// The `--format` that `commits(fromLog:)` reads, NUL-separated, so a
    /// subject or body can hold anything. Run with `-z`, which ends each
    /// commit with one more NUL.
    static let logFormat = ["%H", "%P", "%an", "%ae", "%at", "%cn", "%ce", "%ct", "%s", "%b"]
        .joined(separator: "%x00")

    private static let fieldsPerCommit = 10

    /// The commits in `git log -z --format=<logFormat>` output.
    ///
    /// No field can hold a NUL: git cuts a message at one, and prints a
    /// signature with one as empty fields. A timestamp git can't print
    /// reads as the epoch, as git's own `%aI` shows it.
    static func commits(fromLog output: [UInt8]) -> [Commit] {
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        return stride(from: 0, through: fields.count - fieldsPerCommit, by: fieldsPerCommit).map { start in
            Commit(logFields: Array(fields[start..<start + fieldsPerCommit]))
        }
    }

    /// `fields` holds exactly `fieldsPerCommit` elements, in `logFormat`'s
    /// order.
    private init(logFields fields: [String]) {
        self.init(
            sha: fields[0],
            parents: fields[1].split(separator: " ").map(String.init),
            author: Signature(name: fields[2], email: fields[3], date: Self.date(fromTimestamp: fields[4])),
            committer: Signature(name: fields[5], email: fields[6], date: Self.date(fromTimestamp: fields[7])),
            subject: fields[8],
            body: String(fields[9].reversed().drop { $0.isNewline }.reversed())
        )
    }

    private static func date(fromTimestamp timestamp: String) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64(timestamp) ?? 0))
    }
}
