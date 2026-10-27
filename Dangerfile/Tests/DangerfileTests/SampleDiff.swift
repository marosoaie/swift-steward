/// Pull requests' diffs as `git diff` writes them, for the rule tests.
enum SampleDiff {
    /// An edit to a source file, which adds its line 2.
    static let source = """
        diff --git a/Sources/Steward/Rule.swift b/Sources/Steward/Rule.swift
        index 1111111..2222222 100644
        --- a/Sources/Steward/Rule.swift
        +++ b/Sources/Steward/Rule.swift
        @@ -1,2 +1,3 @@
         import Foundation
        +let unused = 1
         public struct Rule {}

        """

    /// A new release version.
    static let release = """
        diff --git a/Sources/StewardVersion/Release.swift b/Sources/StewardVersion/Release.swift
        index 3333333..4444444 100644
        --- a/Sources/StewardVersion/Release.swift
        +++ b/Sources/StewardVersion/Release.swift
        @@ -1,3 +1,3 @@
         package enum Release {
        -    package static let version = "2.0.0"
        +    package static let version = "2.1.0"
         }

        """

    /// A fixture from another project, with its notice beside it.
    static let fixtureWithNotice = """
        diff --git a/Tests/Fixtures/upstream.diff b/Tests/Fixtures/upstream.diff
        new file mode 100644
        index 0000000..5555555
        --- /dev/null
        +++ b/Tests/Fixtures/upstream.diff
        @@ -0,0 +1 @@
        +diff --git a/x b/x
        diff --git a/Tests/Fixtures/NOTICE b/Tests/Fixtures/NOTICE
        new file mode 100644
        index 0000000..6666666
        --- /dev/null
        +++ b/Tests/Fixtures/NOTICE
        @@ -0,0 +1 @@
        +Copyright (c) Upstream authors

        """

    /// The same, with its entry in the list of third-party notices.
    static let fixtureWithNoticeListed = fixtureWithNotice + """
        diff --git a/THIRD_PARTY_NOTICES.md b/THIRD_PARTY_NOTICES.md
        index 7777777..8888888 100644
        --- a/THIRD_PARTY_NOTICES.md
        +++ b/THIRD_PARTY_NOTICES.md
        @@ -1 +1,2 @@
         | Path | Upstream |
        +| `Tests/Fixtures/upstream.diff` | Upstream |

        """
}
