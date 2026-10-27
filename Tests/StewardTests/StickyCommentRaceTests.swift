@testable import Steward
import Testing

/// Posting while another run posts to the same pull request: a newer
/// commit's, or the same commit's.
@Suite("Posting the sticky summary comment while another run posts")
struct StickyCommentRaceTests {
    @Test("a write whose retry finds the head moved during the pause writes nothing", arguments: [false, true])
    func movedDuringPause(hasComment: Bool) async throws {
        let github = FakeGitHub(head: StickyCommentTests.head)
        let earlier = StickyCommentTests.marker + "Earlier"
        if hasComment {
            await github.addComment(earlier, by: StickyCommentTests.bot)
        }
        let operation = hasComment ? "issues/update-comment" : "issues/create-comment"
        await github.fail(operation, with: .status(502, message: "Bad Gateway"))
        let newer = String(repeating: "b", count: 40)
        let posting = try await StickyCommentTests.post(to: github) { await github.push(newer) }
        guard case .stale(let head) = posting.outcome else { Issue.record("\(posting.outcome)"); return }
        #expect(head == newer)
        #expect(posting.pauses == [.seconds(2)])
        let write = hasComment ? StickyCommentTests.edit(1_001) : StickyCommentTests.create
        let read = StickyCommentTests.read
        #expect(posting.requests == [StickyCommentTests.list, read, write, read])
        #expect(posting.comments.map(\.body) == (hasComment ? [earlier] : []))
        #expect(!posting.log.contains("::warning"))
    }

    // Regression (Copilot review): a deletion's retry didn't re-read the
    // pull request, so it deleted the summary a newer run had just updated.
    @Test("a duplicate's deletion whose retry finds the head moved leaves the newer run's summary")
    func movedDuringDeletionPause() async throws {
        let github = FakeGitHub(head: StickyCommentTests.head)
        let oldest = await github.addComment(StickyCommentTests.marker + "First", by: StickyCommentTests.bot)
        let duplicate = await github.addComment(StickyCommentTests.marker + "Second", by: StickyCommentTests.bot)
        await github.fail("issues/delete-comment", with: .status(502, message: "Bad Gateway"))
        let newer = String(repeating: "b", count: 40)
        let newerSummary = StickyCommentTests.marker + "Newer run's"
        // In the pause, someone deletes the oldest, and the newer commit's
        // run updates the one left.
        let posting = try await StickyCommentTests.post(to: github) {
            await github.push(newer)
            await github.removeComment(oldest)
            await github.editComment(duplicate, to: newerSummary)
        }
        guard case .stale(let head) = posting.outcome else { Issue.record("\(posting.outcome)"); return }
        #expect(head == newer)
        #expect(posting.pauses == [.seconds(2)])
        let (list, read) = (StickyCommentTests.list, StickyCommentTests.read)
        let writes = [StickyCommentTests.edit(oldest), StickyCommentTests.delete(duplicate)]
        #expect(posting.requests == [list, read] + writes + [read])
        #expect(posting.comments.map(\.id) == [duplicate])
        #expect(posting.comments.map(\.body) == [newerSummary])
        #expect(posting.log.contains("so this run stops posting"))
        #expect(!posting.log.contains("::warning"))
    }

    // Regression: a duplicate another run deleted first counted as one this
    // run deleted.
    @Test("a duplicate a run for the same commit deleted first is no failure, and isn't counted")
    func duplicateDeletedElsewhere() async throws {
        let github = FakeGitHub(head: StickyCommentTests.head)
        let oldest = await github.addComment(StickyCommentTests.marker + "First", by: StickyCommentTests.bot)
        let duplicate = await github.addComment(StickyCommentTests.marker + "Second", by: StickyCommentTests.bot)
        await github.fail("issues/update-comment", with: .status(502, message: "Bad Gateway"))
        // In the pause, the other run deletes the duplicate.
        let posting = try await StickyCommentTests.post(to: github) { await github.removeComment(duplicate) }
        guard case .updated(let comment, deletedDuplicates: 0) = posting.outcome else {
            Issue.record("\(posting.outcome)")
            return
        }
        #expect(comment.id.rawValue == oldest)
        let (list, read, update) = (StickyCommentTests.list, StickyCommentTests.read, StickyCommentTests.edit(oldest))
        #expect(posting.requests == [list, read, update, read, update, StickyCommentTests.delete(duplicate)])
        #expect(posting.comments.map(\.id) == [oldest])
        #expect(posting.log.contains("Updated the summary comment: \(comment.webURL)"))
        #expect(!posting.log.contains("duplicate"))
        #expect(!posting.log.contains("::warning"))
    }
}
