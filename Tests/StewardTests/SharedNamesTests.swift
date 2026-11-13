@testable import Steward
import Testing

@Suite("Rules that share a name")
struct SharedNamesTests {
    private static func named(_ names: String...) -> [Rule] {
        names.map { name in Rule(name) { _ in [] } }
    }

    @Test("rules whose names are their own give no warning, nor do none")
    func unique() {
        #expect(Self.named("Lint", "lint", "Format", "Lint ").sharedNamesWarning == nil)
        #expect([Rule]().sharedNamesWarning == nil)
    }

    @Test("one warning lists each shared name once, in the order it first appears, with how many rules have it")
    func shared() {
        let rules = Self.named("Format", "Lint", "Docs", "Lint", "Format", "Lint")
        #expect(rules.sharedNamesWarning == """
            Some rules share a name, so the log and the report can't tell their findings apart: \
            “Format” (2 rules), “Lint” (3 rules). List each rule once, under its own name.
            """)
    }

    @Test("one rule in two groups shares its name with itself")
    func twoGroups() {
        let lint = Rule("Lint") { _ in [] }
        let rules = Rule.group(whenChangesMatch: "a/**") { lint } + Rule.group(whenChangesMatch: "b/**") { lint }
        #expect(rules.sharedNamesWarning?.contains("“Lint” (2 rules)") == true)
    }

    @Test("names compare as strings do, so canonically equivalent spellings are one name")
    func canonicalEquivalence() {
        let composed = String(decoding: [0x43, 0x61, 0x66, 0xC3, 0xA9], as: UTF8.self)
        let decomposed = String(decoding: [0x43, 0x61, 0x66, 0x65, 0xCC, 0x81], as: UTF8.self)
        #expect(Self.named(composed, decomposed).sharedNamesWarning != nil)
    }
}
