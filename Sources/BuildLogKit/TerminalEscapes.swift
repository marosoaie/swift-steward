/// Removes terminal escape sequences (colours, hyperlinks) from a log line,
/// so a coloured log parses like a plain one.
///
/// Swift 6.4's default build system colours diagnostics even when its
/// output is piped, and wraps documentation links in OSC 8 hyperlinks;
/// clang, which it runs with `-fcolor-diagnostics`, colours the path too:
///
///     path:2:9: ESC[1;33mwarning: ESC[1;39mmessageESC[0;0m [#ESC]8;;urlESC\NoUsageESC]8;;ESC\]
///     ESC[1mpath:4:2: ESC[0mESC[0;1;35mwarning: ESC[0mESC[1mmessage [-W#warnings]ESC[0m
///
/// The sequences follow ECMA-48, with ECMA-35 for the rest:
/// - a control sequence: `ESC [`, parameter and intermediate bytes
///   (0x20–0x3F), and a final byte (0x40–0x7E);
/// - a control string (OSC `ESC ]`, and DCS, SOS, PM, APC): up to BEL or
///   the string terminator `ESC \`;
/// - any other escape sequence: intermediate bytes (0x20–0x2F), then a
///   final byte (0x30–0x7E), as in `ESC ( B`, which `tput sgr0` prints.
///
/// A sequence cut short is removed as far as it goes: a byte that can't
/// continue it stays, and a control string without its terminator runs to
/// the end of the line, as a terminal would swallow it. A lone `ESC` is
/// dropped, so no `ESC` survives.
enum TerminalEscapes {
    static let escape: UInt8 = 0x1B

    private static let bell: UInt8 = 0x07

    static func removing(from line: ArraySlice<UInt8>) -> [UInt8] {
        var plain: [UInt8] = []
        plain.reserveCapacity(line.count)
        var rest = line
        // A cursor: each sequence's length depends on its own bytes.
        while let start = rest.firstIndex(of: escape) {
            plain.append(contentsOf: rest[..<start])
            rest = rest[endOfSequence(in: rest, at: start)...]
        }
        plain.append(contentsOf: rest)
        return plain
    }

    /// The index just past the sequence whose `ESC` is at `start`.
    private static func endOfSequence(in line: ArraySlice<UInt8>, at start: Int) -> Int {
        let introducer = line.index(after: start)
        guard introducer < line.endIndex else { return introducer }
        let body = line.index(after: introducer)
        return switch line[introducer] {
        case UInt8(ascii: "["):
            end(of: line, from: body, skipping: 0x20...0x3F, through: 0x40...0x7E)
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            endOfControlString(in: line, from: body)
        case 0x20...0x7E:
            end(of: line, from: introducer, skipping: 0x20...0x2F, through: 0x30...0x7E)
        default:
            introducer
        }
    }

    /// Skips the bytes in `continuing`, then takes one in `final`; any other
    /// byte ends the sequence before it.
    private static func end(
        of line: ArraySlice<UInt8>,
        from index: Int,
        skipping continuing: ClosedRange<UInt8>,
        through final: ClosedRange<UInt8>
    ) -> Int {
        guard let last = line[index...].firstIndex(where: { !continuing.contains($0) }) else {
            return line.endIndex
        }
        return final.contains(line[last]) ? line.index(after: last) : last
    }

    private static func endOfControlString(in line: ArraySlice<UInt8>, from index: Int) -> Int {
        guard let stop = line[index...].firstIndex(where: { $0 == bell || $0 == escape }) else {
            return line.endIndex
        }
        let next = line.index(after: stop)
        if line[stop] == bell {
            return next
        }
        // An ESC other than the terminator's begins the next sequence.
        return next < line.endIndex && line[next] == UInt8(ascii: "\\") ? line.index(after: next) : stop
    }
}
