import OutputEscaping
import Testing

@Suite("Control characters in output people read")
struct ControlCharacterTests {
    @Test("C0, DEL and C1 are written as Swift escapes, and the rest as it is")
    func escapes() {
        #expect("a\u{1B}[2J\u{0}\u{7}\u{7F}\u{85}\u{9B}b".escapingControlCharacters(except: [])
            == #"a\u{1B}[2J\u{0}\u{7}\u{7F}\u{85}\u{9B}b"#)
        // Not controls: a non-breaking space, a line separator, a combining
        // mark, an emoji, and a backslash.
        let plain = "\\u{A0}\u{A0}\u{2028}e\u{301}🙂"
        #expect(plain.escapingControlCharacters(except: []) == plain)
    }

    @Test("what's kept stays, and a \\r\\n, one Character, has each half escaped or kept on its own")
    func kept() {
        #expect("a\tb\nc".escapingControlCharacters(except: ["\n", "\t"]) == "a\tb\nc")
        #expect("a\tb\nc".escapingControlCharacters(except: ["\t"]) == #"a\#tb\u{A}c"#)
        #expect("a\r\nb".escapingControlCharacters(except: ["\n"]) == "a\\u{D}\nb")
    }
}
