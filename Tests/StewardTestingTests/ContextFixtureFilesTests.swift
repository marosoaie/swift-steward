import StewardTesting
import Testing

/// `Context.fixture(diff:files:)`: the files a rule reads at the head, and
/// the check that they hold what the diff says they do.
@Suite("Context.fixture's files")
struct ContextFixtureFilesTests {
    /// `SampleDiff.mixed`'s files at the head, as the diff has them.
    static let mixedFiles = [
        "Sources/App.swift": "import Foundation\nimport Logging\n\nstruct App {}\n",
        "Sources/New.swift": "struct New {}\n",
        "Sources/After.swift": "struct After {}\n// Shared\n",
    ]

    @Test("the files read at the head, files the diff doesn't touch too, and nothing reads at the merge base")
    func reads() async throws {
        let context = try Context.fixture(
            diff: SampleDiff.mixed,
            files: Self.mixedFiles.merging(["README.md": "# App\n"]) { $1 }
        )
        #expect(try await context.contents(ofFileAt: "Sources/App.swift")
            == .bytes(Array("import Foundation\nimport Logging\n\nstruct App {}\n".utf8)))
        #expect(try await context.contents(ofFileAt: "README.md") == .bytes(Array("# App\n".utf8)))
        #expect(try await context.contents(ofFileAt: "Sources") == .notRegularFile)
        #expect(try await context.contents(ofFileAt: "Sources/App.swift", limit: 10) == .tooLarge(size: 48))
        #expect(try await context.contents(ofFileAt: "Docs/Old.md") == .noSuchFile)
        #expect(try await context.contents(ofFileAt: "Sources/App.swift", at: .mergeBase) == .noSuchFile)
    }

    @Test("files with the diff's lines where its hunks say pass the check", arguments: Accepted.allCases)
    func accepted(sample: Accepted) throws {
        _ = try Context.fixture(diff: sample.diff, files: sample.files)
    }

    @Test("a file that disagrees with the diff throws, naming the file and its first line that does",
          arguments: Disagreement.allCases)
    func disagreement(sample: Disagreement) throws {
        let error = #expect(throws: Context.FixtureError.self) {
            try Context.fixture(diff: sample.diff, files: sample.files)
        }
        let mismatch = try #require(error?.mismatches.first)
        #expect(error?.mismatches.count == 1)
        #expect(error?.damage.isEmpty == true)
        #expect(mismatch.path == sample.path)
        #expect(mismatch.line == sample.line)
        #expect(mismatch.reason.contains(sample.reason), "\(mismatch.reason)")
        #expect(error?.description.contains("Context.fixture(diff:files:) needs each file") == true)
        #expect(error?.description.contains(mismatch.description) == true)
    }

    @Test("each file that disagrees is named once, at its first line that does, in the diff's order")
    func severalFiles() {
        let error = #expect(throws: Context.FixtureError.self) {
            try Context.fixture(diff: SampleDiff.mixed, files: [
                "Sources/After.swift": "struct Before {}\n// Unshared\n",
                "Sources/App.swift": "import Foundation\nimport Logger\n\nstruct Application {}\n",
                "Docs/Old.md": "# Old\nGone.\n",
            ])
        }
        #expect(error?.mismatches.map(\.path) == ["Sources/App.swift", "Docs/Old.md", "Sources/After.swift"])
        #expect(error?.mismatches.map(\.line) == [2, nil, 1])
    }

    @Test("a reader a test gives the context itself isn't checked")
    func ownReader() async throws {
        var context = try Context.fixture(diff: SampleDiff.mixed)
        context.files = FakeRepositoryFiles([context.git.head: ["Sources/App.swift": Array("anything\n".utf8)]])
        #expect(try await context.contents(ofFileAt: "Sources/App.swift") == .bytes(Array("anything\n".utf8)))
    }

    /// docs/rule-tests.md's rule that reads a file.
    static let toolsVersion = Rule("Tools version") { context in
        guard context.git.modifiedFiles.contains("Package.swift"),
              case .bytes(let bytes) = try await context.contents(ofFileAt: "Package.swift")
        else { return [] }
        let firstLine = String(decoding: bytes.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
        return firstLine == "// swift-tools-version: 6.2"
            ? [] : [.warning("Build with Swift 6.2.", at: Location(path: "Package.swift", line: 1))]
    }

    @Test("docs/rule-tests.md's test of a rule that reads a file, and the file it gives agrees with its diff")
    func documentedRule() async throws {
        let context = try Context.fixture(
            diff: """
                diff --git a/Package.swift b/Package.swift
                index 1111111..2222222 100644
                --- a/Package.swift
                +++ b/Package.swift
                @@ -2,5 +2,6 @@
                 import PackageDescription

                 let package = Package(
                -    name: "App"
                +    name: "App",
                +    platforms: [.macOS(.v14)]
                 )
                """,
            files: ["Package.swift": """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "App",
                    platforms: [.macOS(.v14)]
                )

                """]
        )
        let findings = try await Self.toolsVersion.evaluate(context)
        #expect(findings == [.warning("Build with Swift 6.2.", at: Location(path: "Package.swift", line: 1))])
    }

    /// Diffs and files that agree.
    enum Accepted: String, CaseIterable, Sendable {
        case mixed = "SampleDiff.mixed with its three files at the head"
        case noNewline = "a file that ends without a newline, as the diff says"
        case crlf = "a file with CRLF line endings"
        case recreatedAsLink = "a file that becomes a link, given nowhere"
        case untouched = "only files the diff doesn't touch"
        case createdEmpty = "an empty file the diff creates"
        case createdUnterminated = "a file the diff creates without a final newline"
        case endTrimmed = "files ending with a hunk that deletes their unterminated last line"

        var diff: String {
            switch self {
            case .mixed, .untouched: SampleDiff.mixed
            case .noNewline: SampleDiff.noNewline
            case .crlf: SampleDiff.crlf
            case .recreatedAsLink: SampleDiff.typeChange
            case .createdEmpty, .createdUnterminated: SampleDiff.created
            case .endTrimmed: SampleDiff.endTrimmed
            }
        }

        var files: [String: String] {
            switch self {
            case .mixed: ContextFixtureFilesTests.mixedFiles
            case .noNewline: ["A.txt": "new"]
            case .crlf: ["A.txt": "a\r\nb\r\n"]
            case .recreatedAsLink: [:]
            case .untouched: ["Docs/New.md": "# New\n", "Package.swift": ""]
            case .createdEmpty: ["Empty.swift": ""]
            case .createdUnterminated: ["Two.txt": "one\ntwo"]
            case .endTrimmed:
                ["A.txt": "keep\n", "B.txt": "keep\nnew\n", "C.txt": "kept\n", "D.txt": "", "E.txt": "first\n"]
            }
        }
    }

    /// Diffs and files that disagree, and where.
    enum Disagreement: String, CaseIterable, Sendable {
        case otherLine = "another line where the diff adds one"
        case tooShort = "a file too short for a hunk"
        case trailingSpace = "a line with a trailing space the diff doesn't have"
        case deleted = "a file the diff deletes"
        case renamedAway = "a file the diff renames"
        case unterminated = "a file without a final newline the diff doesn't mention"
        case terminated = "a final newline where the diff says there's none"
        case lineFeeds = "LF where the diff has CRLF"
        case link = "a file where the diff makes a link"
        case createdLonger = "more lines than the diff creates"
        case createdNotEmpty = "a line in a file the diff creates empty"
        case pastTrimmedEnd = "a line past a hunk that deletes the file's unterminated last line"
        case pastAddedEnd = "a line past one added after the file's unterminated last line, deleted"
        case trimmedNotEmpty = "a line in a file the diff empties of its unterminated line"
        case keptMissing = "no line where a hunk that only deletes keeps one"
        case pastKeptEnd = "a line past the one a hunk keeps as it deletes the file's unterminated last line"

        var diff: String {
            switch self {
            case .otherLine, .tooShort, .trailingSpace, .deleted, .renamedAway, .unterminated: SampleDiff.mixed
            case .terminated: SampleDiff.noNewline
            case .lineFeeds: SampleDiff.crlf
            case .link: SampleDiff.typeChange
            case .createdLonger, .createdNotEmpty: SampleDiff.created
            case .pastTrimmedEnd, .pastAddedEnd, .trimmedNotEmpty, .keptMissing, .pastKeptEnd: SampleDiff.endTrimmed
            }
        }

        var files: [String: String] {
            switch self {
            case .otherLine: ["Sources/App.swift": "import Foundation\nimport Logger\n\nstruct App {}\n"]
            case .tooShort: ["Sources/App.swift": "import Foundation\nimport Logging\n"]
            case .trailingSpace: ["Sources/App.swift": "import Foundation\nimport Logging\n\nstruct App {}\u{20}\n"]
            case .deleted: ["Docs/Old.md": "# Old\nGone.\n"]
            case .renamedAway: ["Sources/Before.swift": "struct Before {}\n// Shared\n"]
            case .unterminated: ["Sources/New.swift": "struct New {}"]
            case .terminated: ["A.txt": "new\n"]
            case .lineFeeds: ["A.txt": "a\nb\n"]
            case .link: ["link": "target"]
            case .createdLonger: ["Sources/New.swift": "struct New {}\nextra\n"]
            case .createdNotEmpty: ["Empty.swift": "\n"]
            case .pastTrimmedEnd: ["A.txt": "keep\nextra\n"]
            case .pastAddedEnd: ["B.txt": "keep\nnew\nold"]
            case .trimmedNotEmpty: ["D.txt": "old\n"]
            case .keptMissing: ["E.txt": ""]
            case .pastKeptEnd: ["E.txt": "first\nsecond\n"]
            }
        }

        var path: String {
            files.keys.first ?? ""
        }

        var line: Int? {
            switch self {
            case .otherLine: 2
            case .tooShort: 3
            case .trailingSpace: 4
            case .deleted, .renamedAway, .link: nil
            case .unterminated, .terminated, .lineFeeds, .createdNotEmpty, .trimmedNotEmpty, .keptMissing: 1
            case .createdLonger, .pastTrimmedEnd, .pastKeptEnd: 2
            case .pastAddedEnd: 3
            }
        }

        /// A phrase the reason holds.
        var reason: String {
            switch self {
            case .otherLine: #"the diff has "import Logging", and the file has "import Logger""#
            case .tooShort: "the diff has a line 3, and the file has 2 lines"
            case .createdLonger: "the diff creates the file with 1 line, and the file has 2"
            case .createdNotEmpty: "the diff creates the file with 0 lines, and the file has 1"
            case .pastTrimmedEnd: "deletes the file's old last line, leaving it with 1 line, and the file has 2"
            case .pastAddedEnd: "leaving it with 2 lines, and the file has 3"
            case .trimmedNotEmpty: "leaving it with 0 lines, and the file has 1"
            case .keptMissing: "the diff keeps a line 1 before what it deletes, and the file has 0 lines"
            case .pastKeptEnd: "leaving it with 1 line, and the file has 2"
            case .trailingSpace: "they differ only in trailing whitespace"
            case .deleted: "the diff deletes it, so the head has no such file"
            case .renamedAway: "renames it to Sources/After.swift"
            case .unterminated: "the file ends here without a newline, and the diff doesn't say so"
            case .terminated: "the diff says the file ends here without a newline"
            case .lineFeeds: #"the diff has "a\r", and the file has "a""#
            case .link: "the diff makes it a symbolic link"
            }
        }
    }
}
