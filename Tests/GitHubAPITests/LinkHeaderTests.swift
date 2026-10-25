@testable import GitHubAPI
import Testing

@Suite("The link header names a next page only through rel=next")
struct LinkHeaderTests {
    static let base = "https://api.github.com/repositories/1/issues/2/comments?per_page=5"

    @Test("a next relation, quoted or bare, alone or among others, is a next page", arguments: [
        #"<\#(base)&page=2>; rel="next", <\#(base)&page=2>; rel="last""#,
        #"<\#(base)&page=1>; rel="prev", <\#(base)&page=3>; rel="next""#,
        "<\(base)&page=2>; rel=next",
        #"<\#(base)&page=2>;rel="next""#,
        #"<\#(base)&page=2>; REL="Next""#,
        #"<\#(base)&page=2>; title="x"; rel="next last""#,
    ])
    func next(link: String) {
        #expect(LinkHeader.namesNextPage(link))
    }

    @Test("the first, previous, or last page alone isn't a next page", arguments: [
        "",
        "garbage",
        #"<\#(base)&page=1>; rel="prev", <\#(base)&page=1>; rel="first""#,
        #"<https://api.github.com/next?page=2>; rel="last""#,
        #"<\#(base)&page=2>; rel="nextpage""#,
        #"<\#(base)&page=2>; title="next""#,
        #"<\#(base)&page=2>; rel"#,
    ])
    func noNext(link: String) {
        #expect(!LinkHeader.namesNextPage(link))
    }
}
