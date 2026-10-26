@testable import Steward
import Testing

@Suite("Repository names")
struct RepositoryNameTests {
    @Test("owner/name parses, and anything else doesn't", arguments: [
        ("marosoaie/swift-steward", "marosoaie/swift-steward"),
        ("o/r", "o/r"),
        ("o", nil), ("o/r/x", nil), ("/r", nil), ("o/", nil), ("./r", nil), ("o/..", nil), ("o/r x", nil), ("", nil),
    ] as [(String, String?)])
    func ownerAndName(text: String, expected: String?) {
        #expect(RepositoryName(text)?.description == expected)
    }

    @Test("a remote on the server's host names its repository, in every URL form git takes", arguments: [
        "https://github.com/o/r.git", "https://github.com/o/r", "https://github.com/o/r/", "http://GitHub.com/o/r",
        "https://user:secret@github.com/o/r.git", "ssh://git@github.com/o/r.git", "ssh://git@github.com:22/o/r",
        "git://github.com/o/r.git", "git@github.com:o/r.git", "github.com:o/r", "git@github.com:/o/r.git",
    ])
    func remotes(url: String) {
        #expect(RepositoryName(remoteURL: url, host: "github.com") == RepositoryName("o/r"))
    }

    @Test("a remote elsewhere, or that isn't a repository's URL, names none", arguments: [
        "https://gitlab.com/o/r.git", "git@gitlab.com:o/r.git", "github-work:o/r.git", "/srv/git/o/r.git",
        "../o/r", "file:///srv/o/r.git", "https://github.com/o", "https://github.com/o/r/pulls", "C:/o/r",
    ])
    func otherRemotes(url: String) {
        #expect(RepositoryName(remoteURL: url, host: "github.com") == nil)
    }
}
