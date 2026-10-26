import GitDiffKit
@testable import Steward
import Testing

@Suite("The rule builder")
struct RuleBuilderTests {
    /// docs/danger.md, section 1's example, without the built-in rule.
    struct DocumentedChecks: Dangerfile {
        static var rules: [Rule] {
            Rule("Changelog") { context in
                guard !context.git.modifiedFiles.contains("CHANGELOG.md") else { return [] }
                return [.warning("Add a CHANGELOG entry.")]
            }

            Rule("No new Objective-C") { context in
                context.git.createdFiles
                    .filter { $0.hasSuffix(".m") }
                    .map { .failure("Write \($0) in Swift.", at: Location(path: $0)) }
            }
        }
    }

    enum BranchingChecks {
        static let shared = [Self.named("shared 1"), Self.named("shared 2")]

        @RuleBuilder
        static func rules(strict: Bool) -> [Rule] {
            Self.named("first")
            if strict {
                Self.named("strict")
            }
            if strict {
                Self.named("if")
            } else {
                Self.named("else")
            }
            switch strict {
            case true: Self.named("switch strict")
            case false: Self.named("switch lenient")
            }
            for index in 1...2 {
                Self.named("loop \(index)")
            }
            if #available(macOS 26, *) {
                Self.named("available")
            }
            shared
        }

        static func named(_ name: String) -> Rule {
            Rule(name) { _ in [] }
        }
    }

    struct EmptyChecks: Dangerfile {
        static var rules: [Rule] {}
    }

    @Test("the documented Dangerfile lists its rules in order, and they read the context")
    func documented() async throws {
        #expect(DocumentedChecks.rules.map(\.name) == ["Changelog", "No new Objective-C"])
        let context = Context.stub(diff: """
            diff --git a/Legacy.m b/Legacy.m
            new file mode 100644
            --- /dev/null
            +++ b/Legacy.m
            @@ -0,0 +1 @@
            +int main(void) { return 0; }

            """)
        let findings = try await DocumentedChecks.rules.asyncFlatMap { try await $0.evaluate(context) }
        #expect(findings == [
            .warning("Add a CHANGELOG entry."),
            .failure("Write Legacy.m in Swift.", at: Location(path: "Legacy.m")),
        ])
    }

    @Test("if, else, switch, for, availability, and arrays add their rules in order", arguments: [false, true])
    func branches(strict: Bool) {
        let expected = ["first"] + (strict ? ["strict", "if", "switch strict"] : ["else", "switch lenient"])
            + ["loop 1", "loop 2", "available", "shared 1", "shared 2"]
        #expect(BranchingChecks.rules(strict: strict).map(\.name) == expected)
    }

    @Test("an empty Dangerfile has no rules")
    func empty() {
        #expect(EmptyChecks.rules.isEmpty)
    }
}

private extension Array {
    func asyncFlatMap<Transformed>(
        _ transform: (Element) async throws -> [Transformed]
    ) async rethrows -> [Transformed] {
        var result: [Transformed] = []
        // Imperative: each element awaits, which the combinators can't.
        for element in self {
            result += try await transform(element)
        }
        return result
    }
}
