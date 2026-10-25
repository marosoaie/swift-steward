@testable import GitHubAPI
import Testing

@Suite("The summary marker counts on the first line only")
struct SummaryMarkerTests {
    let marker = SummaryMarker.steward

    @Test("marked text gives back exactly the body", arguments: ["", "a", "a\nb", "\n", "\r\n", "ünïcode 🚀\n\n"])
    func roundTrip(body: String) {
        #expect(marker.body(ofMarked: marker.marking(body)) == body)
    }

    @Test("a CRLF after the marker counts, as GitHub's web editor writes it")
    func crlf() {
        #expect(marker.body(ofMarked: "<!-- steward-summary -->\r\nbody\r\nmore") == "body\r\nmore")
    }

    @Test("the marker alone, without a line ending, is an empty summary")
    func markerOnly() {
        #expect(marker.body(ofMarked: "<!-- steward-summary -->")?.isEmpty == true)
    }

    @Test("text that doesn't start with the marker line isn't a summary", arguments: [
        "",
        "LGTM",
        "> <!-- steward-summary -->\n> quoted in a reply",
        "See the summary:\n<!-- steward-summary -->\nbody",
        " <!-- steward-summary -->\nindented",
        "<!-- steward-summary --> trailing text\nbody",
        "<!-- steward-summary -- >\nbody",
        "<!-- STEWARD-SUMMARY -->\nbody",
        "<!-- steward-summary -->\r\r\nbody",
    ])
    func notSummaries(text: String) {
        #expect(marker.body(ofMarked: text) == nil)
    }
}
