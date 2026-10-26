import BuildLogKit
import DiffDiagnostics
import Foundation
import GitDiffKit
@testable import Steward
import Testing

/// How the rule resolves a diagnostic's path with the checkout at hand: to
/// the file the checkout has at that path, when it has one, and otherwise by
/// the longest known suffix, as `steward filter` resolves every path.
@Suite("Resolving a diagnostic's path in the checkout")
struct DiagnosticsPathResolutionTests {
    /// The pull request adds lines 1–3 of the root-level `Foo.swift`.
    private static let changes = ChangedLines(files: ["Foo.swift": LineRangeSet([1...3])])

    /// A checkout with a root-level `Foo.swift` and an untouched namesake,
    /// `Other/Foo.swift`.
    private struct Checkout {
        let path: String

        init() throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("steward-checkout-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent("Other", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("let foo = 1\n".utf8).write(to: url.appendingPathComponent("Foo.swift"))
            try Data("let other = 1\n".utf8).write(to: url.appendingPathComponent("Other/Foo.swift"))
            path = url.path
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func diagnostic(_ path: String, _ line: Int) -> Diagnostic {
        Diagnostic(path: path, line: line, column: nil, severity: .warning, message: "m")
    }

    private func locations(_ diagnostics: [MatchedDiagnostic]) -> [String] {
        diagnostics.map { "\($0.path):\($0.line)" }
    }

    @Test("a diagnostic in an untouched Other/Foo.swift doesn't land on the changed root-level Foo.swift")
    func untouchedNamesake() throws {
        let checkout = try Checkout()
        defer { checkout.remove() }
        let diagnostics = [
            diagnostic("\(checkout.path)/Other/Foo.swift", 2),
            diagnostic("\(checkout.path)/Foo.swift", 3),
        ]

        let (matched, dropped) = ChangedLineDiagnostics.matched(
            diagnostics,
            lineMap: .identity,
            changes: Self.changes,
            workspace: checkout.path
        )
        #expect(locations(matched) == ["Foo.swift:3"])
        #expect(dropped == 0)
        // `steward filter`'s matching is unchanged: it can't see the
        // checkout, so the namesake still lands by suffix.
        #expect(locations(DiagnosticMatcher.match(diagnostics, against: Self.changes, repoRoot: checkout.path))
            == ["Foo.swift:2", "Foo.swift:3"])
    }

    @Test(
        "a path the checkout has no file at, or one not in plain form, still resolves by suffix, as filter resolves it",
        arguments: ["{root}/Gone/Foo.swift", "Gone/Foo.swift", "/elsewhere/Other/Foo.swift", "./Foo.swift"]
    )
    func suffixFallback(path: String) throws {
        let checkout = try Checkout()
        defer { checkout.remove() }
        let diagnostics = [diagnostic(path.replacingOccurrences(of: "{root}", with: checkout.path), 2)]

        let (matched, _) = ChangedLineDiagnostics.matched(
            diagnostics,
            lineMap: .identity,
            changes: Self.changes,
            workspace: checkout.path
        )
        #expect(locations(matched) == ["Foo.swift:2"])
        #expect(matched == DiagnosticMatcher.match(diagnostics, against: Self.changes, repoRoot: checkout.path))
    }
}
