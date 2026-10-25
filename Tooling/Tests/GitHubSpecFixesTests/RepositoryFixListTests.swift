import Foundation
import GitHubSpecFixes
import Testing
import Yams

/// Checks on the repository's own fix list and generator input, which live
/// outside this package (Specs/github, Tests/GitHubAPITests).
@Suite("The repository's fix list is valid, evidenced, and in force")
struct RepositoryFixListTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // GitHubSpecFixesTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Tooling
        .deletingLastPathComponent()

    static func contents(of path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    let list: SpecFixList

    init() throws {
        list = try SpecFixList(yaml: Self.contents(of: "Specs/github/fixes.yaml"))
    }

    @Test("every fixture a fix names is recorded in Tests/GitHubAPITests/Fixtures")
    func fixturesExist() {
        let fixtures = Self.root.appendingPathComponent("Tests/GitHubAPITests/Fixtures")
        list.fixes.compactMap(\.fixture).forEach { fixture in
            #expect(
                FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(fixture).path),
                "\(fixture) is missing"
            )
        }
    }

    static let correctionTests = "Tests/GitHubAPITests/SpecFixRegressionTests.swift"
    static let adaptationTests = "Tooling/Tests/GitHubSpecFixesTests/SpecAdaptationTests.swift"

    /// The fixes that tests in `source` are named after: `@Test("<fix>: …")`.
    static func testedFixes(in source: String) -> Set<String> {
        Set(source.matches(of: /@Test\(\s*"([a-z0-9-]+):\s/).map { String($0.output.1) })
    }

    var corrections: [SpecFix] {
        list.fixes.filter(\.edit.correctsUpstream)
    }

    var adaptations: [SpecFix] {
        list.fixes.filter { !$0.edit.correctsUpstream }
    }

    @Test("every correction has a regression test that names the fix and decodes its fixture")
    func correctionsAreTested() throws {
        let tests = try Self.contents(of: Self.correctionTests)
        let tested = Self.testedFixes(in: tests)
        corrections.forEach { fix in
            #expect(tested.contains(fix.name), "no test in \(Self.correctionTests) is named after \(fix.name)")
            let replayed = fix.fixture.map { "\"\($0.replacingOccurrences(of: ".http", with: ""))\"" }
            #expect(replayed.map(tests.contains) == true, "no test replays \(fix.fixture ?? "a fixture")")
        }
    }

    @Test("every adaptation has a test that names the fix and checks the generator input")
    func adaptationsAreTested() throws {
        let tested = try Self.testedFixes(in: Self.contents(of: Self.adaptationTests))
        adaptations.forEach { fix in
            #expect(tested.contains(fix.name), "no test in \(Self.adaptationTests) is named after \(fix.name)")
        }
    }

    // A dropped fix leaves its test passing on a regenerated client that no
    // longer needs it, so the test would outlive its reason silently.
    @Test("every test named after a fix names a fix on the list, in the file for its kind")
    func noTestOutlivesItsFix() throws {
        let correctionNames = Set(corrections.map(\.name))
        let adaptationNames = Set(adaptations.map(\.name))
        #expect(try Self.testedFixes(in: Self.contents(of: Self.correctionTests)).subtracting(correctionNames) == [])
        #expect(try Self.testedFixes(in: Self.contents(of: Self.adaptationTests)).subtracting(adaptationNames) == [])
    }

    @Test("a test is named after a fix only by a fix-shaped prefix, wherever the name starts")
    func testedFixNames() {
        let source = """
            @Test("update-comment-404: decodes the 404")
            @Test(
                "drop-x-webhooks: has no x-webhooks"
            )
            @Test("pulls/get decodes a closed, a merged and an open draft pull request", arguments: [1])
            @Test("a 401 stays undocumented: no operation declares it")
            let text = "delete-comment-404: not a test name"
            """
        #expect(Self.testedFixes(in: source) == ["update-comment-404", "drop-x-webhooks"])
    }

    // The committed generator input already has every fix applied, so it is
    // exactly what upstream looks like once it has caught up with all of them.
    @Test("applied to their own output, every fix reports itself as redundant, by name")
    func everyFixDetectsItsOwnResult() throws {
        let fixed = try #require(try Yams.compose(yaml: Self.contents(of: "Specs/github/openapi.yaml")))
        let problem = #expect(throws: SpecFixList.Problem.self) {
            try list.applied(to: fixed)
        }
        guard case let .stale(failures) = problem else {
            Issue.record("expected stale fixes, got \(String(describing: problem))")
            return
        }
        #expect(failures.map(\.fix) == list.fixes.map(\.name))
        #expect(failures.allSatisfy { if case .redundant = $0.reason { true } else { false } })
    }
}
