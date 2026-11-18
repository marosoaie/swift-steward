@testable import Steward
import StewardTesting

extension RuleChangedFilesTests {
    /// Edits A.swift's second line, creates New.swift, deletes Old.swift,
    /// renames Moved.swift unchanged, edits a generated file and the
    /// README, adds a link, a submodule and a file of 43 bytes.
    static let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 1111111..2222222 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1,2 +1,2 @@
         import Steward
        -let a = 1
        +let a = 2
        diff --git a/Sources/New.swift b/Sources/New.swift
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/Sources/New.swift
        @@ -0,0 +1 @@
        +struct New {}
        diff --git a/Sources/Old.swift b/Sources/Old.swift
        deleted file mode 100644
        index 4444444..0000000
        --- a/Sources/Old.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -struct Old {}
        diff --git a/Old/Moved.swift b/Sources/Moved.swift
        similarity index 100%
        rename from Old/Moved.swift
        rename to Sources/Moved.swift
        diff --git a/Sources/Generated/G.swift b/Sources/Generated/G.swift
        index 5555555..6666666 100644
        --- a/Sources/Generated/G.swift
        +++ b/Sources/Generated/G.swift
        @@ -1 +1 @@
        -let g = 1
        +let g = 2
        diff --git a/README.md b/README.md
        index 7777777..8888888 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -# Old
        +# New
        diff --git a/Sources/Link.swift b/Sources/Link.swift
        new file mode 120000
        index 0000000..9999999
        --- /dev/null
        +++ b/Sources/Link.swift
        @@ -0,0 +1 @@
        +A.swift
        \\ No newline at end of file
        diff --git a/Sources/Vendor b/Sources/Vendor
        new file mode 160000
        index 0000000..1234567
        --- /dev/null
        +++ b/Sources/Vendor
        @@ -0,0 +1 @@
        +Subproject commit 1234567890123456789012345678901234567890
        diff --git a/Sources/Big.swift b/Sources/Big.swift
        new file mode 100644
        index 0000000..abcdef0
        --- /dev/null
        +++ b/Sources/Big.swift
        @@ -0,0 +1 @@
        +let big = "012345678901234567890123456789"

        """

    static let files = [
        "Sources/A.swift": "import Steward\nlet a = 2\n",
        "Sources/New.swift": "struct New {}\n",
        "Sources/Moved.swift": "struct Moved {}\n",
        "Sources/Generated/G.swift": "let g = 2\n",
        "README.md": "# New\n",
        "Sources/Big.swift": "let big = \"012345678901234567890123456789\"\n",
    ]

    /// The reads a `CountingFiles` was asked for: each batch's size, and
    /// how many single reads.
    actor Reads {
        var batches: [Int] = []
        var singles = 0

        func record(batch size: Int) {
            batches.append(size)
        }

        func recordSingle() {
            singles += 1
        }
    }

    /// A reader that counts its reads, then reads through another, whose
    /// batch read is the protocol's default.
    struct CountingFiles: RepositoryFiles {
        let reads: Reads
        let files: FakeRepositoryFiles

        func contents(ofFileAt path: String, in commit: String, limit: Int) async throws -> FileContents {
            await reads.recordSingle()
            return try await files.contents(ofFileAt: path, in: commit, limit: limit)
        }

        func contents(ofFilesAt paths: [String], in commit: String, limit: Int) async throws -> [FileContents] {
            await reads.record(batch: paths.count)
            return try await files.contents(ofFilesAt: paths, in: commit, limit: limit)
        }
    }
}
