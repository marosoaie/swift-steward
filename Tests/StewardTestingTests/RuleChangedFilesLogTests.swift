import StewardTesting
import Testing

/// `Rule.changedFiles` with a check that writes to the run's log, from
/// outside Steward.
@Suite("A per-file rule's log")
struct RuleChangedFilesLogTests {
    /// `SampleDiff.created`'s files: 14, 0 and 7 bytes.
    static let files = ["Sources/New.swift": "struct New {}\n", "Empty.swift": "", "Two.txt": "one\ntwo"]

    @Test("the check takes the file alone or the file and the log, by its closure's parameters alone")
    func overloads() async throws {
        let context = try Context.fixture(diff: SampleDiff.created, files: Self.files)
        let alone = Rule.changedFiles("Sizes", in: "**") { file in
            [.message("\(file.contents.count) bytes", at: Location(path: file.path))]
        }
        let logged = Rule.changedFiles("Sizes", in: "**") { file, log in
            log.write("Sizes: read \(file.path)")
            return [.message("\(file.contents.count) bytes", at: Location(path: file.path))]
        }
        let anonymous = Rule.changedFiles("Sizes", in: "**") {
            [.message("\($0.contents.count) bytes", at: Location(path: $0.path))]
        }
        let expected: [Finding] = [
            .message("14 bytes", at: Location(path: "Sources/New.swift")),
            .message("0 bytes", at: Location(path: "Empty.swift")),
            .message("7 bytes", at: Location(path: "Two.txt")),
        ]
        #expect(try await alone.evaluate(context) == expected)
        #expect(try await logged.evaluate(context) == expected)
        #expect(try await anonymous.evaluate(context) == expected)
    }

    @Test("a line the check writes for a file shows in the run's log, in diff order with the files it skipped",
          arguments: [Run.Mode.actions, .dryRun])
    func lines(mode: Run.Mode) async throws {
        var context = try Context.fixture(diff: SampleDiff.created, files: Self.files)
        context.run.mode = mode
        let outcome = await PerFileLogging.run(on: context)
        #expect(outcome.log.contains("""
            Sizes: skipped Sources/New.swift, 14 bytes, over the limit of 10
            Sizes: read Empty.swift
            Sizes: read Two.txt
            Sizes: 2 findings

            """), "\(outcome.log)")
        #expect(outcome.report?.findings.map(\.location?.path) == ["Empty.swift", "Two.txt"])
    }
}
