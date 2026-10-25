/// The hidden first line that tells Steward's summary comment from the other
/// comments on a pull request.
///
/// An HTML comment, so GitHub renders nothing for it. Only the first line
/// counts: a reply that quotes the summary (`> <!-- … -->`) or mentions the
/// marker further down isn't a summary comment.
struct SummaryMarker: Sendable, Hashable {
    /// The marker `GitHubHost` uses outside tests.
    static let steward = SummaryMarker(line: "<!-- steward-summary -->")

    /// One line, without its line ending.
    let line: String

    /// The text to post: the marker line, then `body`.
    func marking(_ body: String) -> String {
        "\(line)\n\(body)"
    }

    /// The text after the marker line, or nil when `text` doesn't start with
    /// it.
    ///
    /// Compares bytes, not characters: in a `String`, `\r\n` is a single
    /// character, and comments edited in GitHub's web editor come back with
    /// CRLF line endings.
    func body(ofMarked text: String) -> String? {
        let bytes = text.utf8
        let newline = bytes.firstIndex(of: UInt8(ascii: "\n"))
        let firstLine = bytes[..<(newline ?? bytes.endIndex)]
        let content = firstLine.last == UInt8(ascii: "\r") ? firstLine.dropLast() : firstLine
        guard content.elementsEqual(line.utf8) else {
            return nil
        }
        return newline.map { String(text[bytes.index(after: $0)...]) } ?? ""
    }
}
