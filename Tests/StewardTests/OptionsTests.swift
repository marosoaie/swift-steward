@testable import Steward
import Testing

@Suite("A run's options")
struct OptionsTests {
    @Test("no arguments means a run with every default")
    func defaults() throws {
        #expect(try Options(arguments: []) == Options())
        #expect(Options().summaryAuthor == "github-actions[bot]")
    }

    @Test("every option parses, its value either after = or as the next argument", arguments: [
        ["--base", "main", "--pull-request", "27", "--report", "out.json", "--fail-on-post-error",
         "--summary-author", "app[bot]"],
        ["--base=main", "--pull-request=27", "--report=out.json", "--fail-on-post-error", "--summary-author=app[bot]"],
    ])
    func everyOption(arguments: [String]) throws {
        var expected = Options()
        expected.base = "main"
        expected.pullRequest = 27
        expected.reportPath = "out.json"
        expected.failsOnPostError = true
        expected.summaryAuthor = "app[bot]"
        #expect(try Options(arguments: arguments) == expected)
    }

    @Test("a value may hold = signs, and a repeated option keeps its last value")
    func repeatedAndEquals() throws {
        let options = try Options(arguments: ["--base", "a", "--base=refs/x=y", "--report=r=1.json"])
        #expect(options.base == "refs/x=y")
        #expect(options.reportPath == "r=1.json")
    }

    @Test("both spellings of help ask for it", arguments: ["--help", "-h"])
    func help(argument: String) throws {
        #expect(try Options(arguments: ["--base", "main", argument]).showsHelp)
    }

    @Test("a malformed command line names what's wrong", arguments: [
        (["--bsae", "main"], OptionsError.unknownOption("--bsae")),
        (["--fail-on-post-error=yes"], .unknownOption("--fail-on-post-error=yes")),
        (["main"], .unexpectedArgument("main")),
        (["--base"], .missingValue("--base")),
        (["--base="], .missingValue("--base")),
        (["--base", "--report", "r.json"], .missingValue("--base")),
        (["--report", ""], .missingValue("--report")),
        (["--summary-author"], .missingValue("--summary-author")),
        (["--summary-author="], .missingValue("--summary-author")),
        (["--pull-request", "0"], .invalidPullRequest("0")),
        (["--pull-request=-3"], .invalidPullRequest("-3")),
        (["--pull-request", "#27"], .invalidPullRequest("#27")),
        (["--pull-request=99999999999999999999"], .invalidPullRequest("99999999999999999999")),
    ])
    func malformed(arguments: [String], error: OptionsError) {
        #expect(throws: error) { try Options(arguments: arguments) }
    }

    @Test("the help text names the program, every option, and every exit status")
    func usage() {
        let usage = Options.usage(program: "PullRequestChecks")
        #expect(usage.hasPrefix("USAGE: PullRequestChecks [--base <ref>]"))
        let mentions = [
            "--base <ref>", "--pull-request <number>", "--report <path>", "--fail-on-post-error",
            "--summary-author <login>", "-h, --help",
            "  0  ", "  1  ", "  2  ",
        ]
        #expect(mentions.allSatisfy { usage.contains($0) })
    }

    @Test("the worse exit status wins: broken over failures over clean")
    func exitStatus() {
        #expect([Steward.ExitStatus.clean, .broken, .failures].max() == .broken)
        #expect(max(Steward.ExitStatus.clean, .failures) == .failures)
        #expect([Steward.ExitStatus.clean, .failures, .broken].map(\.rawValue) == [0, 1, 2])
    }
}
