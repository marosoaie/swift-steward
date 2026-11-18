extension Context {
    /// A fixture that a real run couldn't have: its diff isn't one git
    /// writes, or a file given with it isn't the head's.
    ///
    /// Usually a hunk header whose line counts don't match its lines, or a
    /// file that doesn't hold the diff's lines where its hunk headers say.
    public struct FixtureError: Error, Sendable, Equatable, CustomStringConvertible {
        // swiftlint:disable nesting - a mismatch exists only in the error that lists it
        /// A file given to `fixture(diff:files:)` that the diff says the
        /// head can't have.
        public struct Mismatch: Sendable, Equatable, CustomStringConvertible {
            /// The file's path, as `files` names it.
            public var path: String
            /// The first line of the file that disagrees with the diff; nil
            /// when the whole file does, as one the diff deletes.
            public var line: Int?
            /// What disagrees, as a sentence.
            public var reason: String

            /// Creates a mismatch from its parts.
            public init(path: String, line: Int?, reason: String) {
                self.path = path
                self.line = line
                self.reason = reason
            }

            /// The path, the line, and the reason, on one line.
            public var description: String {
                "\(path)\(line.map { ", line \($0)" } ?? ""): \(reason)"
            }
        }
        // swiftlint:enable nesting

        /// What the parser reported, in diff order.
        public var damage: [DamageReport]
        /// Where the files given disagree with the diff: the first place
        /// in each file, in diff order.
        public var mismatches: [Mismatch]

        /// Creates an error for the damage the parser reported, and the
        /// files that disagree with the diff.
        public init(damage: [DamageReport] = [], mismatches: [Mismatch] = []) {
            self.damage = damage
            self.mismatches = mismatches
        }

        /// A sentence saying what's wrong and how to fix it, then each
        /// damage report and each mismatch on a line.
        public var description: String {
            let damaged = damage.isEmpty ? [] : [
                """
                Context.fixture(diff:) needs a diff git could write, and this one is damaged; \
                check each hunk header's line counts against its lines.
                """,
            ] + damage.map(\.sentence)
            let mismatched = mismatches.isEmpty ? [] : [
                """
                Context.fixture(diff:files:) needs each file as the head commit has it, holding the \
                diff's context and added lines at the numbers its hunk headers give; check these \
                files against the diff, or give a test that needs them to disagree a reader of its \
                own (context.files).
                """,
            ] + mismatches.map(\.description)
            return (damaged + mismatched).joined(separator: "\n")
        }
    }
}
