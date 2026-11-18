@testable import Dangerfile
import StewardTesting
import Testing

@Suite("JSON")
struct JSONTests {
    /// Creates `Fixtures/event.json` and `Fixtures/notes.txt`, and edits
    /// `Fixtures/response.json`'s second line.
    static let diff = """
        diff --git a/Fixtures/event.json b/Fixtures/event.json
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/Fixtures/event.json
        @@ -0,0 +1 @@
        +{"action": "opened"}
        diff --git a/Fixtures/notes.txt b/Fixtures/notes.txt
        new file mode 100644
        index 0000000..2222222
        --- /dev/null
        +++ b/Fixtures/notes.txt
        @@ -0,0 +1 @@
        +{ not JSON
        diff --git a/Fixtures/response.json b/Fixtures/response.json
        index 3333333..4444444 100644
        --- a/Fixtures/response.json
        +++ b/Fixtures/response.json
        @@ -1,3 +1,3 @@
         {
        -  "number": 1
        +  "number": one
         }

        """

    @Test("a JSON file that doesn't parse fails at its path, and one that does passes")
    func parses() async throws {
        let context = try Context.fixture(diff: Self.diff, files: [
            "Fixtures/event.json": #"{"action": "opened"}"# + "\n",
            "Fixtures/notes.txt": "{ not JSON\n",
            "Fixtures/response.json": "{\n  \"number\": one\n}\n",
        ])
        let findings = try await Checks.json.evaluate(context)
        #expect(findings.map(\.kind) == [.failure])
        #expect(findings.map(\.location) == [Location(path: "Fixtures/response.json")])
    }

    @Test("a JSON file that's a symbolic link isn't read: the rule warns at it")
    func link() async throws {
        let diff = """
            diff --git a/Fixtures/linked.json b/Fixtures/linked.json
            new file mode 120000
            index 0000000..1111111
            --- /dev/null
            +++ b/Fixtures/linked.json
            @@ -0,0 +1 @@
            +event.json
            \\ No newline at end of file

            """
        let findings = try await Checks.json.evaluate(Context.fixture(diff: diff))
        #expect(findings == [.warning("""
            Rule “JSON” skipped `Fixtures/linked.json`, a symbolic link. A file the rule should never check \
            belongs in its `excluding:` pattern.
            """, at: Location(path: "Fixtures/linked.json"))])
    }

    @Test("a pull request whose JSON files all parse passes")
    func allParse() async throws {
        let fixed = Self.diff.replacing(#"+  "number": one"#, with: #"+  "number": 2"#)
        let context = try Context.fixture(diff: fixed, files: [
            "Fixtures/event.json": #"{"action": "opened"}"# + "\n",
            "Fixtures/response.json": "{\n  \"number\": 2\n}\n",
        ])
        #expect(try await Checks.json.evaluate(context).isEmpty)
    }
}
