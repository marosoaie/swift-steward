import OutputEscaping
import Testing

@Suite("Output people read")
struct EscapedForReadingTests {
    @Test("C0, DEL and C1 are written as Swift escapes, and the rest as it is")
    func escapes() {
        #expect("a\u{1B}[2J\u{0}\u{7}\u{7F}\u{85}\u{9B}b".escapedForReading(keeping: [])
            == #"a\u{1B}[2J\u{0}\u{7}\u{7F}\u{85}\u{9B}b"#)
        // Not controls: a non-breaking space, a line separator, a combining
        // mark, an emoji, and a backslash.
        let plain = "\\u{A0}\u{A0}\u{2028}e\u{301}🙂"
        #expect(plain.escapedForReading(keeping: []) == plain)
    }

    @Test("what's kept stays, and a \\r\\n, one Character, has each half escaped or kept on its own")
    func kept() {
        #expect("a\tb\nc".escapedForReading(keeping: ["\n", "\t"]) == "a\tb\nc")
        #expect("a\tb\nc".escapedForReading(keeping: ["\t"]) == #"a\#tb\u{A}c"#)
        #expect("a\r\nb".escapedForReading(keeping: ["\n"]) == "a\\u{D}\nb")
    }

    @Test("##[ anywhere, and a :: that starts a line after whitespace, lose a character to an escape")
    func commandSyntax() {
        #expect("a##[b ###[c ##\u{1B}[d".escapedForReading(keeping: []) == #"a#\u{23}[b ##\u{23}[c ##\u{1B}[d"#)
        #expect(" \t\u{A0}::e::x".escapedForReading(keeping: ["\t"]) == " \t\u{A0}\\u{3A}:e::x")
        #expect("a\n::e::x\r :::f::y".escapedForReading(keeping: ["\n", "\r"]) == "a\n\\u{3A}:e::x\r \\u{3A}::f::y")
        // Not at a line's start: after text, after an escaped line break or
        // control, or a colon that isn't doubled.
        ["a ::e::x", ": :e::x", ":e::x"].forEach { #expect($0.escapedForReading(keeping: []) == $0) }
        #expect("a\n::e::x".escapedForReading(keeping: []) == #"a\u{A}::e::x"#)
        #expect("\u{B}::e::x".escapedForReading(keeping: []) == #"\u{B}::e::x"#)
    }

    @Test(
        "the runner reads a command in each input and none once it's escaped, whatever line breaks are kept",
        arguments: [
            "::error::x", "  ::warning file=a.swift,line=1::x", "\t::group::g", "\u{A0}::debug::d",
            "a\n::endgroup::", "a\r::notice::b", "a\r\n::error::x", "::\u{301}e::x",
            "x ##[error]legacy", "##[group]g", "###[x]y", "a\n##[section]s",
        ]
    )
    func runnerReadsNoCommand(input: String) {
        #expect(!WorkflowCommand.commands(in: input).isEmpty)
        [[], ["\t"], ["\n", "\t"], ["\n", "\r", "\t"]].forEach { kept in
            #expect(WorkflowCommand.commands(in: input.escapedForReading(keeping: kept)).isEmpty, "\(kept)")
        }
    }
}
