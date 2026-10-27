@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Conflict markers")
struct ConflictMarkerTests {
    @Test("a committed conflict fails at each marker that opens or closes it")
    func committed() async throws {
        let context = try Context.fixture(diff: SampleDiff.committedConflict)
        let findings = try await Checks.conflictMarkers.evaluate(context)
        #expect(findings == [
            .failure("Resolve this merge conflict.", at: Location(path: "Config/settings.json", line: 2)),
            .failure("Resolve this merge conflict.", at: Location(path: "Config/settings.json", line: 6)),
        ])
    }

    @Test("removing the markers passes")
    func resolved() async throws {
        let context = try Context.fixture(diff: SampleDiff.resolvedConflict)
        let findings = try await Checks.conflictMarkers.evaluate(context)
        #expect(findings.isEmpty)
    }

    @Test("markers the pull request didn't add pass")
    func untouched() async throws {
        let context = try Context.fixture(diff: """
            diff --git a/Notes/merging.txt b/Notes/merging.txt
            index 1111111..2222222 100644
            --- a/Notes/merging.txt
            +++ b/Notes/merging.txt
            @@ -1,3 +1,4 @@
             <<<<<<< ours
            +Keep both sides.
             >>>>>>> theirs
             That's what a conflict looks like.

            """)
        let findings = try await Checks.conflictMarkers.evaluate(context)
        #expect(findings.isEmpty)
    }

    @Test(
        "a line that isn't a marker passes",
        arguments: [#"let marker = "<<<<<<< HEAD""#, "<<<<<<<<<< arrows", ">>>>>>>>"]
    )
    func notMarker(line: String) async throws {
        let context = try Context.fixture(diff: """
            diff --git a/Notes/merging.txt b/Notes/merging.txt
            index 1111111..2222222 100644
            --- a/Notes/merging.txt
            +++ b/Notes/merging.txt
            @@ -1 +1,2 @@
             Merging
            +\(line)

            """)
        let findings = try await Checks.conflictMarkers.evaluate(context)
        #expect(findings.isEmpty)
    }
}
