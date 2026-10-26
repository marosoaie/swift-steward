import GitDiffKit
import Steward
import Testing

@Suite("A pull request's files, by how they changed")
struct GitChangesTests {
    /// One file of each kind of change, as `git diff -M` prints them.
    private let changes = GitChanges(
        diff: Diff(diff: """
            diff --git a/Added.swift b/Added.swift
            new file mode 100644
            index 0000000..1111111
            --- /dev/null
            +++ b/Added.swift
            @@ -0,0 +1 @@
            +added
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
            @@ -1 +1 @@
            -old
            +new
            diff --git a/Old.swift b/New.swift
            similarity index 100%
            rename from Old.swift
            rename to New.swift
            diff --git a/Original.swift b/Copy.swift
            similarity index 100%
            copy from Original.swift
            copy to Copy.swift
            diff --git a/run.sh b/run.sh
            old mode 100644
            new mode 100755
            diff --git a/image.png b/image.png
            index 1111111..2222222 100644
            Binary files a/image.png and b/image.png differ

            """),
        commits: [],
        mergeBase: String(repeating: "a", count: 40),
        head: String(repeating: "b", count: 40)
    )

    @Test("added and copied files are created")
    func created() {
        #expect(changes.createdFiles == ["Added.swift", "Copy.swift"])
    }

    @Test("deleted files are deleted, under their old path")
    func deleted() {
        #expect(changes.deletedFiles == ["Deleted.swift"])
    }

    @Test("everything on both sides is modified, renamed files under their new path, mode and binary changes included")
    func modified() {
        #expect(changes.modifiedFiles == ["Modified.swift", "New.swift", "run.sh", "image.png"])
    }

    @Test("renamed files carry both paths")
    func renamed() {
        #expect(changes.renamedFiles == [GitChanges.Rename(from: "Old.swift", to: "New.swift")])
    }

    @Test("a file is found by its new path, or by its old one when it was deleted or renamed")
    func fileAtPath() {
        #expect(changes.file(at: "Modified.swift")?.header.change == .modified)
        #expect(changes.file(at: "New.swift")?.header.change == .renamed(similarity: 100))
        #expect(changes.file(at: "Old.swift")?.header.newPath?.string == "New.swift")
        #expect(changes.file(at: "Deleted.swift")?.header.change == .deleted)
        #expect(changes.file(at: "Elsewhere.swift") == nil)
    }

    @Test("a path that isn't UTF-8 is listed decoded lossily, and stays exact in the diff")
    func nonUTF8Path() {
        let diff = Diff(diff: Array("diff --git a/caf".utf8) + [0xE9] + Array(" b/caf".utf8) + [0xE9] + Array("""

            new file mode 100644
            index 0000000..1111111

            """.utf8))
        let changes = GitChanges(diff: diff, commits: [], mergeBase: "", head: "")
        #expect(changes.createdFiles == ["caf\u{FFFD}"])
        #expect(changes.diff.files.first?.header.newPath?.bytes == Array("caf".utf8) + [0xE9])
    }
}
