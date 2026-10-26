import DiffDiagnostics
import Testing

@Suite("DiagnosticPathResolver")
struct DiagnosticPathResolverTests {
    static let paths = ["Foo.swift", "Sources/App/Foo.swift", "Sources/App/Bar.swift", "Docs/Read Me.md"]

    @Test("a known path resolves to itself, and an unknown one to nothing")
    func exactPaths() {
        var resolver = DiagnosticPathResolver(paths: Self.paths)
        #expect(resolver.resolve("Sources/App/Bar.swift") == "Sources/App/Bar.swift")
        #expect(resolver.resolve("Docs/Read Me.md") == "Docs/Read Me.md")
        #expect(resolver.resolve("Sources/App/Baz.swift") == nil)
        #expect(resolver.resolve("") == nil)
    }

    @Test("an absolute path resolves to the longest known path it ends with, on a component boundary")
    func suffixes() {
        var resolver = DiagnosticPathResolver(paths: Self.paths)
        #expect(resolver.resolve("/ci/Sources/App/Foo.swift") == "Sources/App/Foo.swift")
        #expect(resolver.resolve("/ci/Other/Foo.swift") == "Foo.swift")
        #expect(resolver.resolve("/ci/Sources/App/FooBar.swift") == nil)
        #expect(resolver.resolve("/ci/MyFoo.swift") == nil)
    }

    @Test("the repository root is stripped first, with or without its trailing slash")
    func repositoryRoot() {
        var withSlash = DiagnosticPathResolver(paths: Self.paths, repoRoot: "/ci/checkout/")
        var withoutSlash = DiagnosticPathResolver(paths: Self.paths, repoRoot: "/ci/checkout")
        #expect(withSlash.resolve("/ci/checkout/Foo.swift") == "Foo.swift")
        #expect(withoutSlash.resolve("/ci/checkout/Foo.swift") == "Foo.swift")
        // A root that only shares a prefix with the path's directory isn't stripped.
        #expect(withoutSlash.resolve("/ci/checkout2/Sources/App/Bar.swift") == "Sources/App/Bar.swift")
        // Elsewhere, suffixes still resolve.
        #expect(withSlash.resolve("/elsewhere/Sources/App/Bar.swift") == "Sources/App/Bar.swift")
    }

    @Test("resolving the same path again gives the same answer, found or not")
    func cachedAnswers() {
        var resolver = DiagnosticPathResolver(paths: Self.paths, repoRoot: "/ci")
        let paths = ["/ci/Foo.swift", "/x/Sources/App/Foo.swift", "/x/Nope.swift"]
        let first = paths.map { resolver.resolve($0) }
        let second = paths.map { resolver.resolve($0) }
        #expect(first == ["Foo.swift", "Sources/App/Foo.swift", nil])
        #expect(second == first)
    }

    @Test("no known paths resolve nothing")
    func noPaths() {
        var resolver = DiagnosticPathResolver(paths: [String]())
        #expect(resolver.resolve("/ci/Foo.swift") == nil)
    }
}
