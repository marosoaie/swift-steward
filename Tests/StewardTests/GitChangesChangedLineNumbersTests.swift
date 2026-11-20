import GitDiffKit
@testable import Steward
import Testing

@Suite("The lines a pull request adds or rewrites, read from its diff")
struct GitChangesChangedLineNumbersTests {
    private static let diff = """
        diff --git a/Added.swift b/Added.swift
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/Added.swift
        @@ -0,0 +1,2 @@
        +one
        +two
        diff --git a/Deleted.swift b/Deleted.swift
        deleted file mode 100644
        index 1111111..0000000
        --- a/Deleted.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -deleted
        diff --git a/Modified.swift b/Modified.swift
        index 1111111..2222222 100644
        --- a/Modified.swift
        +++ b/Modified.swift
        @@ -1,3 +1,3 @@
        -old
        +new
         same
         same
        @@ -10,2 +10,4 @@
         same
        +new
        +new
         same
        diff --git a/Old.swift b/Renamed.swift
        similarity index 80%
        rename from Old.swift
        rename to Renamed.swift
        index 1111111..2222222 100644
        --- a/Old.swift
        +++ b/Renamed.swift
        @@ -2 +2 @@
        -old
        +new
        diff --git a/Moved.swift b/Moved2.swift
        similarity index 100%
        rename from Moved.swift
        rename to Moved2.swift
        diff --git a/image.png b/image.png
        index 1111111..2222222 100644
        Binary files a/image.png and b/image.png differ
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755

        """

    @Test("they're what ChangedLineNumbers(diff:) reads from the same diff, files without added lines left out")
    func parity() {
        let changes = GitChanges(diff: Diff(diff: Self.diff), commits: [], mergeBase: "a", head: "b")
        #expect(changes.changedLineNumbers == ChangedLineNumbers(diff: Self.diff))
        #expect(changes.changedLineNumbers.files == [
            "Added.swift": LineRangeSet([1...2]),
            "Modified.swift": LineRangeSet([1...1, 11...12]),
            "Renamed.swift": LineRangeSet([2...2]),
        ])
    }

    @Test("a file's lines are its lines in the whole set, and none for a file without added lines", arguments: [
        "Added.swift", "Modified.swift", "Renamed.swift", "Old.swift", "Deleted.swift", "Moved2.swift",
        "image.png", "run.sh", "Missing.swift", "", "added.swift",
    ])
    func oneFile(path: String) {
        let changes = GitChanges(diff: Diff(diff: Self.diff), commits: [], mergeBase: "a", head: "b")
        #expect(changes.changedLineNumbers(in: path) == changes.changedLineNumbers.files[path] ?? LineRangeSet())
    }

    @Test("a path given twice, as git writes a file that becomes a link, gets both entries' lines")
    func typeChange() {
        let diff = """
            diff --git a/link b/link
            deleted file mode 120000
            index 1111111..0000000
            --- a/link
            +++ /dev/null
            @@ -1 +0,0 @@
            -target
            \\ No newline at end of file
            diff --git a/link b/link
            new file mode 100644
            index 0000000..2222222
            --- /dev/null
            +++ b/link
            @@ -0,0 +1,2 @@
            +now
            +a file

            """
        let changes = GitChanges(diff: Diff(diff: diff), commits: [], mergeBase: "a", head: "b")
        #expect(changes.changedLineNumbers(in: "link") == LineRangeSet([1...2]))
        #expect(changes.changedLineNumbers.files == ["link": LineRangeSet([1...2])])
    }

    @Test("a long run of added lines is one range")
    func longRun() {
        let count = 100_000
        let diff = """
            diff --git a/Big.swift b/Big.swift
            new file mode 100644
            index 0000000..1111111
            --- /dev/null
            +++ b/Big.swift
            @@ -0,0 +1,\(count) @@
            \(String(repeating: "+line\n", count: count))
            """
        let changes = GitChanges(diff: Diff(diff: diff), commits: [], mergeBase: "a", head: "b")
        #expect(changes.changedLineNumbers.files["Big.swift"]?.ranges == [1...count])
    }
}
