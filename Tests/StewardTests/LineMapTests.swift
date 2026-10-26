import GitDiffKit
@testable import Steward
import Testing

@Suite("The line map from the built commit to the head")
struct LineMapTests {
    /// The map read from `diff`, a `git diff -U0 -M <head> <built>`.
    private func map(_ diff: String) -> LineMap {
        var parser = DiffEventParser(consumer: LineMap.Collector())
        parser.consume(diff)
        return parser.finalize().map
    }

    /// The head line of each built line from 1 through `lines` in `path`.
    private func headLines(through lines: Int, of path: String, in map: LineMap) -> [Int?] {
        (1...lines).map { map.headLocation(ofLine: $0, inFile: path)?.line }
    }

    @Test("the identity maps every line of every file to itself")
    func identity() {
        #expect(LineMap.identity.headLocation(ofLine: 7, inFile: "a.swift") == Location(path: "a.swift", line: 7))
        #expect(LineMap.identity.headPath(ofFile: "a.swift") == "a.swift")
    }

    @Test("a line number below 1 maps nowhere")
    func nonPositiveLine() {
        #expect(LineMap.identity.headLocation(ofLine: 0, inFile: "a.swift") == nil)
        #expect(LineMap.identity.headLocation(ofLine: -3, inFile: "a.swift") == nil)
    }

    @Test("lines the base inserted have no head line, and the lines below shift up")
    func insertion() {
        let map = map("""
            diff --git a/a.swift b/a.swift
            index 1111111..2222222 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -2,0 +3,2 @@ func f() {
            +inserted
            +inserted

            """)
        #expect(headLines(through: 6, of: "a.swift", in: map) == [1, 2, nil, nil, 3, 4])
        #expect(map.headLocation(ofLine: 1000, inFile: "a.swift") == Location(path: "a.swift", line: 998))
    }

    @Test("lines the base removed shift the lines below down")
    func removal() {
        let map = map("""
            diff --git a/a.swift b/a.swift
            index 1111111..2222222 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -3,2 +2,0 @@
            -removed
            -removed

            """)
        #expect(headLines(through: 4, of: "a.swift", in: map) == [1, 2, 5, 6])
    }

    @Test("removing lines at the top of a file shifts every line")
    func removalAtTop() {
        let map = map("""
            diff --git a/a.swift b/a.swift
            index 1111111..2222222 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -1,2 +0,0 @@
            -removed
            -removed

            """)
        #expect(headLines(through: 3, of: "a.swift", in: map) == [3, 4, 5])
    }

    @Test("a replaced line has no head line, and the hunks' shifts add up")
    func severalHunks() {
        let map = map("""
            diff --git a/a.swift b/a.swift
            index 1111111..2222222 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -2,3 +2 @@
            -old
            -old
            -old
            +new
            @@ -8 +6,3 @@
            -old
            +new
            +new
            +new

            """)
        // Built 2 replaces head 2–4; built 6–8 replace head 8.
        #expect(headLines(through: 10, of: "a.swift", in: map) == [1, nil, 5, 6, 7, nil, nil, nil, 9, 10])
    }

    @Test("a file the base renamed maps back to its head path")
    func rename() {
        let map = map("""
            diff --git a/Old.swift b/New.swift
            similarity index 90%
            rename from Old.swift
            rename to New.swift
            index 1111111..2222222 100644
            --- a/Old.swift
            +++ b/New.swift
            @@ -0,0 +1 @@
            +// header

            """)
        #expect(map.headPath(ofFile: "New.swift") == "Old.swift")
        #expect(map.headLocation(ofLine: 1, inFile: "New.swift") == nil)
        #expect(map.headLocation(ofLine: 2, inFile: "New.swift") == Location(path: "Old.swift", line: 1))
    }

    @Test("a pure rename maps every line to the same line of the head path")
    func pureRename() {
        let map = map("""
            diff --git a/Old.swift b/New.swift
            similarity index 100%
            rename from Old.swift
            rename to New.swift

            """)
        #expect(map.headLocation(ofLine: 12, inFile: "New.swift") == Location(path: "Old.swift", line: 12))
    }

    @Test("a file the base added has no head counterpart")
    func addedFile() {
        let map = map("""
            diff --git a/New.swift b/New.swift
            new file mode 100644
            index 0000000..2222222
            --- /dev/null
            +++ b/New.swift
            @@ -0,0 +1 @@
            +new

            """)
        #expect(map.headPath(ofFile: "New.swift") == nil)
        #expect(map.headLocation(ofLine: 1, inFile: "New.swift") == nil)
        #expect(map.headLocation(ofLine: 1, inFile: "Other.swift") == Location(path: "Other.swift", line: 1))
    }

    @Test("a binary file keeps its path, but none of its lines map")
    func binaryFile() {
        let map = map("""
            diff --git a/image.png b/image.png
            index 1111111..2222222 100644
            Binary files a/image.png and b/image.png differ

            """)
        #expect(map.headPath(ofFile: "image.png") == "image.png")
        #expect(map.headLocation(ofLine: 1, inFile: "image.png") == nil)
    }

    @Test("a mode change alone maps every line to itself")
    func modeChange() {
        let map = map("""
            diff --git a/run.sh b/run.sh
            old mode 100644
            new mode 100755

            """)
        #expect(map.headLocation(ofLine: 4, inFile: "run.sh") == Location(path: "run.sh", line: 4))
    }

    @Test("a file whose diff is too damaged to read maps nowhere, rather than to itself")
    func damagedFile() {
        // A header over the parser's 64 lines: the file is abandoned.
        let map = map("""
            diff --git a/a.swift b/a.swift
            \(String(repeating: "old mode 100644\n", count: 70))\
            --- a/a.swift
            +++ b/a.swift
            @@ -1 +1 @@
            -old
            +new
            diff --git a/b.swift b/b.swift
            index 1111111..2222222 100644
            --- a/b.swift
            +++ b/b.swift
            @@ -1 +1 @@
            -old
            +new

            """)
        #expect(map.headLocation(ofLine: 5, inFile: "a.swift") == nil)
        #expect(map.headLocation(ofLine: 5, inFile: "b.swift") == Location(path: "b.swift", line: 5))
    }

    @Test("a line number so large the shift would overflow maps nowhere instead of trapping")
    func overflow() {
        let map = map("""
            diff --git a/a.swift b/a.swift
            index 1111111..2222222 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -1,5 +0,0 @@
            -removed
            -removed
            -removed
            -removed
            -removed

            """)
        #expect(map.headLocation(ofLine: Int.max - 1, inFile: "a.swift") == nil)
        #expect(map.headLocation(ofLine: 1, inFile: "a.swift") == Location(path: "a.swift", line: 6))
    }

    @Test("among many hunks, a line shifts by exactly the hunks above it")
    func lookupAcrossManyHunks() {
        // One line inserted after every 10 lines of a 100 000-line file:
        // built line 11k is new, and the lines after it shift by k.
        let shifts = (1...10_000).map { hunk in
            LineMap.Shift(start: hunk * 11, end: hunk * 11 + 1, offset: -hunk)
        }
        #expect(LineMap.headLine(ofBuiltLine: 10, shifts: shifts) == 10)
        #expect(LineMap.headLine(ofBuiltLine: 11, shifts: shifts) == nil)
        #expect(LineMap.headLine(ofBuiltLine: 12, shifts: shifts) == 11)
        #expect(LineMap.headLine(ofBuiltLine: 54_999, shifts: shifts) == 50_000)
        #expect(LineMap.headLine(ofBuiltLine: 55_000, shifts: shifts) == nil)
        #expect(LineMap.headLine(ofBuiltLine: 110_000, shifts: shifts) == nil)
        #expect(LineMap.headLine(ofBuiltLine: 110_001, shifts: shifts) == 100_001)
    }
}
