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

    @Test("every correction has a regression test that names the fix and decodes its fixture")
    func correctionsAreTested() throws {
        let tests = try Self.contents(of: "Tests/GitHubAPITests/SpecFixRegressionTests.swift")
        list.fixes.filter(\.edit.correctsUpstream).forEach { fix in
            #expect(tests.contains("\"\(fix.name): "), "no test is named after \(fix.name)")
            let replayed = fix.fixture.map { "\"\($0.replacingOccurrences(of: ".http", with: ""))\"" }
            #expect(replayed.map(tests.contains) == true, "no test replays \(fix.fixture ?? "a fixture")")
        }
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
