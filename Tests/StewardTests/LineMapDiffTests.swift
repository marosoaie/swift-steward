@testable import Steward
import Testing

/// `LineMap(diff:)`, as a test of a rule writes one: which way its diff
/// runs, and how context lines read.
@Suite("A line map read from a diff")
struct LineMapDiffTests {
    /// The head lines of the built lines 1 through `lines` of a.swift.
    private func headLines(through lines: Int, in map: LineMap) -> [Int?] {
        (1...lines).map { map.headLocation(ofLine: $0, inFile: "a.swift")?.line }
    }

    /// From a head of lines h1 through h10 to a built commit that inserts
    /// b after h2, removes h5, and replaces h8 with x, as `git diff -U0`
    /// writes it.
    static let withoutContext = """
        diff --git a/a.swift b/a.swift
        index 1111111..2222222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -2,0 +3 @@
        +b
        @@ -5 +5,0 @@
        -h5
        @@ -8 +8 @@
        -h8
        +x

        """

    /// The same change with git's three context lines, in one hunk.
    static let withContext = """
        diff --git a/a.swift b/a.swift
        index 1111111..2222222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1,10 +1,10 @@
         h1
         h2
        +b
         h3
         h4
        -h5
         h6
         h7
        -h8
        +x
         h9
         h10

        """

    @Test("context lines change nothing: a diff with them maps as its -U0 twin does")
    func contextLines() {
        let map = LineMap(diff: Self.withContext)
        #expect(map == LineMap(diff: Self.withoutContext))
        #expect(headLines(through: 11, in: map) == [1, 2, nil, 3, 4, 6, 7, nil, 9, 10, 11])
    }

    @Test("the map runs from the built commit to the head: the reverse diff maps the other way")
    func direction() {
        let headToBuilt = LineMap(diff: """
            diff --git a/a.swift b/a.swift
            index 1111111..2222222 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -0,0 +1,2 @@
            +base 1
            +base 2

            """)
        let builtToHead = LineMap(diff: """
            diff --git a/a.swift b/a.swift
            index 2222222..1111111 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -1,2 +0,0 @@
            -base 1
            -base 2

            """)
        // Built line 3 is head line 1, below the two lines the base added.
        #expect(headLines(through: 3, in: headToBuilt) == [nil, nil, 1])
        #expect(headLines(through: 3, in: builtToHead) == [3, 4, 5])
        #expect(headToBuilt != builtToHead)
    }

    @Test("a hunk cut short, by the next file or by the end of the diff, maps none of its file's lines",
          arguments: [true, false])
    func cutShort(byNextFile: Bool) {
        let map = LineMap(diff: """
            diff --git a/a.swift b/a.swift
            index 1111111..2222222 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -1 +1 @@
            -old
            \(byNextFile ? Self.intactFile : "")
            """)
        #expect(headLines(through: 3, in: map) == [nil, nil, nil])
        #expect(map.headPath(ofFile: "a.swift") == "a.swift")
        // The file after it maps as its own hunk says.
        #expect(map.headLocation(ofLine: 2, inFile: "b.swift")?.line == (byNextFile ? 1 : 2))
    }

    /// A file after the one cut short, whose own hunk is whole: it inserts
    /// a line at the top.
    static let intactFile = """
        diff --git a/b.swift b/b.swift
        index 3333333..4444444 100644
        --- a/b.swift
        +++ b/b.swift
        @@ -0,0 +1 @@
        +inserted

        """
}
