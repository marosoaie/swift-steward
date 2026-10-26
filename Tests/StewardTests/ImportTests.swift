import Steward
import Testing

/// A Dangerfile's view of Steward: this file imports no other module, so,
/// with MemberImportVisibility on, it builds only while Steward re-exports
/// GitDiffKit and PullRequestHosting.
@Suite("Importing Steward alone")
struct ImportTests {
    @Test("with only import Steward, a rule reads the pull request and the diff, their members and types")
    func reexports() async throws {
        let rule = Rule("Reads both") { context in
            let added = context.git.file(at: "a.swift")?.lines.first { $0.info.kind == .addition }
            return [.message("\(context.pullRequest.title): line \(added?.info.newNumber ?? 0)")]
        }
        let context = Context.stub(diff: """
            diff --git a/a.swift b/a.swift
            --- a/a.swift
            +++ b/a.swift
            @@ -1 +1,2 @@
             let a = 1
            +let b = 2

            """, title: "Add b")
        #expect(try await rule.evaluate(context).map(\.text) == ["Add b: line 2"])
        let head: PullRequest.Branch = context.pullRequest.head
        let path: DiffPath? = context.git.diff.files.first?.header.newPath
        #expect(head.name == "feature")
        #expect(path?.string == "a.swift")
    }
}
