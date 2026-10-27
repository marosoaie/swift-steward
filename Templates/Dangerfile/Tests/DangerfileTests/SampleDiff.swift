/// Pull requests' diffs as `git diff` writes them, for the rule tests.
enum SampleDiff {
    /// An edit under `Sources/`, and nothing else.
    static let sources = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,3 @@
         import Foundation
        +let greeting = "Hello"
         print(greeting)

        """

    /// The same edit, with its changelog entry.
    static let sourcesWithChangelog = sources + """
        diff --git a/CHANGELOG.md b/CHANGELOG.md
        index 3333333..4444444 100644
        --- a/CHANGELOG.md
        +++ b/CHANGELOG.md
        @@ -1,2 +1,3 @@
         # Changelog
        +- Greet the user.
         - Start the app.

        """

    /// The same edit, deleting the changelog.
    static let sourcesDeletingChangelog = sources + """
        diff --git a/CHANGELOG.md b/CHANGELOG.md
        deleted file mode 100644
        index 3333333..0000000
        --- a/CHANGELOG.md
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -# Changelog
        -- Start the app.

        """

    /// A file moved out of `Sources/`, unchanged.
    static let moveOutOfSources = """
        diff --git a/Sources/Legacy.swift b/Archive/Legacy.swift
        similarity index 100%
        rename from Sources/Legacy.swift
        rename to Archive/Legacy.swift

        """

    /// An edit outside `Sources/`.
    static let readme = """
        diff --git a/README.md b/README.md
        index 5555555..6666666 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1,2 @@
         # App
        +Greets the user.

        """

    /// A merge conflict committed as git left it, markers and all.
    static let committedConflict = """
        diff --git a/Config/settings.json b/Config/settings.json
        index 7777777..8888888 100644
        --- a/Config/settings.json
        +++ b/Config/settings.json
        @@ -1,3 +1,7 @@
         {
        +<<<<<<< HEAD
           "greeting": "Hello"
        +=======
        +  "greeting": "Hi"
        +>>>>>>> feature
         }

        """

    /// That conflict, resolved.
    static let resolvedConflict = """
        diff --git a/Config/settings.json b/Config/settings.json
        index 8888888..7777777 100644
        --- a/Config/settings.json
        +++ b/Config/settings.json
        @@ -1,7 +1,3 @@
         {
        -<<<<<<< HEAD
           "greeting": "Hello"
        -=======
        -  "greeting": "Hi"
        ->>>>>>> feature
         }

        """
}
