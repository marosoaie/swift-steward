@testable import Steward
import Testing

/// How `Rule.changedFiles`' failure for a name that isn't UTF-8 writes it:
/// as git quotes a path.
@Suite("A changed file's name, quoted as git quotes it")
struct RuleChangedFilesQuotingTests {
    @Test("each kind of byte is quoted as git ls-files quotes it")
    func gitQuoting() {
        // `git ls-files` prints this name as "a\"b\\c\td\033e\177f\351.swift".
        // One `+` chain of these parts takes Linux's type checker past its
        // time limit.
        let parts: [[UInt8]] = [Array("a\"b\\c\td\u{1B}e\u{7F}f".utf8), [0xE9], Array(".swift".utf8)]
        let name = parts.flatMap(\.self)
        #expect(Rule.quoted(name) == #"a\"b\\c\td\033e\177f\351.swift"#)
    }

    @Test("the control characters C names are quoted by their letters", arguments: Array(UInt8(0x07)...0x0D))
    func namedControls(byte: UInt8) {
        let letters: [UInt8: String] = [0x07: "a", 0x08: "b", 0x09: "t", 0x0A: "n", 0x0B: "v", 0x0C: "f", 0x0D: "r"]
        #expect(Rule.quoted([byte]) == "\\" + (letters[byte] ?? ""))
    }
}
