/// Diffs as `git diff` writes them, for the tests to build contexts from.
enum SampleDiff {
    /// Edits Sources/App.swift, deletes Docs/Old.md, creates
    /// Sources/New.swift, and renames Sources/Before.swift to
    /// Sources/After.swift with an edit: 3 lines added and 3 deleted
    /// across 4 files.
    static let mixed = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,4 @@
         import Foundation
        +import Logging
        \u{20}
         struct App {}
        diff --git a/Docs/Old.md b/Docs/Old.md
        deleted file mode 100644
        index 3333333..0000000
        --- a/Docs/Old.md
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -# Old
        -Gone.
        diff --git a/Sources/New.swift b/Sources/New.swift
        new file mode 100644
        index 0000000..4444444
        --- /dev/null
        +++ b/Sources/New.swift
        @@ -0,0 +1 @@
        +struct New {}
        diff --git a/Sources/Before.swift b/Sources/After.swift
        similarity index 50%
        rename from Sources/Before.swift
        rename to Sources/After.swift
        index 5555555..6666666 100644
        --- a/Sources/Before.swift
        +++ b/Sources/After.swift
        @@ -1,2 +1,2 @@
        -struct Before {}
        +struct After {}
         // Shared

        """

    /// Turns the file `link` into a symbolic link: git deletes the file
    /// and creates the link, and GitHub counts one changed file.
    static let typeChange = """
        diff --git a/link b/link
        deleted file mode 100644
        index 1111111..0000000
        --- a/link
        +++ /dev/null
        @@ -1 +0,0 @@
        -text
        diff --git a/link b/link
        new file mode 120000
        index 0000000..2222222
        --- /dev/null
        +++ b/link
        @@ -0,0 +1 @@
        +target
        \\ No newline at end of file

        """

    /// A hunk that claims three lines on each side and has one.
    static let cutShort = """
        diff --git a/A.swift b/A.swift
        index 1111111..2222222 100644
        --- a/A.swift
        +++ b/A.swift
        @@ -1,3 +1,3 @@
        -let a = 1
        +let a = 2

        """
}
