import Foundation
import GitKit
import Testing
@testable import EditorUI

private func comment(
    _ path: String, _ line: Int, side: ReviewComment.Side = .new, staged: Bool = false, code: String = "code", _ body: String = "fix"
) -> ReviewComment {
    ReviewComment(path: path, staged: staged, side: side, line: line, lineText: code, body: body)
}

@MainActor
struct ReviewCommentStoreTests {
    let store = ReviewCommentStore()
    let root = URL(filePath: "/repo/worktree", directoryHint: .isDirectory)

    @Test func ordersByPathThenLineKeepingTiesInInsertionOrder() {
        let b9 = comment("b.swift", 9)
        let a12 = comment("a.swift", 12)
        let a3 = comment("a.swift", 3)
        let a12Again = comment("a.swift", 12, side: .old)
        for comment in [b9, a12, a3, a12Again] { store.add(comment, in: root) }
        #expect(store.comments(in: root).map(\.id) == [a3.id, a12.id, a12Again.id, b9.id])
    }

    @Test func updatesAndRemovesById() {
        let first = comment("a.swift", 1, "old")
        let second = comment("a.swift", 2)
        store.add(first, in: root)
        store.add(second, in: root)
        store.update(first.id, body: "new", in: root)
        #expect(store.comments(in: root).first?.body == "new")
        store.remove(first.id, in: root)
        #expect(store.comments(in: root).map(\.id) == [second.id])
        store.update(UUID(), body: "ignored", in: root)
        store.remove(UUID(), in: root)
        #expect(store.comments(in: root).map(\.body) == ["fix"])
    }

    @Test func addingAKnownIdReplacesIt() {
        var edited = comment("a.swift", 1)
        store.add(edited, in: root)
        edited.body = "again"
        store.add(edited, in: root)
        #expect(store.comments(in: root).map(\.body) == ["again"])
    }

    @Test func keepsWorktreesApart() {
        let other = URL(filePath: "/repo/other")
        store.add(comment("a.swift", 1), in: root)
        store.add(comment("a.swift", 1), in: other)
        store.removeAll(in: root)
        #expect(store.comments(in: root).isEmpty)
        #expect(store.comments(in: other).count == 1)
    }

    @Test func treatsEquivalentRootURLsAsOneWorktree() {
        store.add(comment("a.swift", 1), in: URL(filePath: "/repo/worktree"))
        #expect(store.comments(in: URL(filePath: "/repo/worktree/")).count == 1)
        #expect(store.comments(in: URL(filePath: "/repo/x/../worktree/.")).count == 1)
        #expect(store.comments(in: URL(filePath: "/repo/worktree2")).isEmpty)
        #expect(ReviewCommentStore.key(URL(filePath: "/")) == "/")
    }
}

@MainActor
struct ReviewCommentPersistenceTests {
    let file = FileManager.default.temporaryDirectory
        .appending(path: "archipel-tests-\(UUID().uuidString)/nested/review-comments.json")
    let root = URL(filePath: "/repo/worktree", directoryHint: .isDirectory)
    let other = URL(filePath: "/repo/other", directoryHint: .isDirectory)

    private func cleanUp() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent())
    }

    @Test func commentsComeBackFromTheFile() {
        defer { cleanUp() }
        let store = ReviewCommentStore(fileURL: file)
        let first = comment("a.swift", 3, side: .old, staged: true, code: "let x = 1", "Why?")
        let second = comment("a.swift", 9)
        store.add(second, in: root)
        store.add(first, in: root)
        store.add(comment("b.swift", 1), in: other)
        store.saveNow()

        let reloaded = ReviewCommentStore(fileURL: file)
        #expect(reloaded.comments(in: root) == [first, second])
        #expect(reloaded.comments(in: other).count == 1)
    }

    @Test func changesAreWrittenAfterTheDelay() async throws {
        defer { cleanUp() }
        let store = ReviewCommentStore(fileURL: file)
        store.add(comment("a.swift", 1), in: root)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Polled, since the write happens on a timer.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ReviewCommentStore(fileURL: file).comments(in: root).count == 1)
    }

    @Test func removedCommentsStayRemoved() {
        defer { cleanUp() }
        let store = ReviewCommentStore(fileURL: file)
        store.add(comment("a.swift", 1), in: root)
        store.saveNow()
        store.removeAll(in: root)
        store.saveNow()
        #expect(ReviewCommentStore(fileURL: file).comments(in: root).isEmpty)
    }

    @Test func dropsCommentsOfWorktreesThatAreGone() {
        defer { cleanUp() }
        let store = ReviewCommentStore(fileURL: file)
        store.add(comment("a.swift", 1), in: root)
        store.add(comment("b.swift", 1), in: other)
        // The same worktree spelled with a trailing slash still counts as kept.
        store.retain(only: [URL(filePath: "/repo/worktree/")])
        store.saveNow()

        let reloaded = ReviewCommentStore(fileURL: file)
        #expect(reloaded.comments(in: root).count == 1)
        #expect(reloaded.comments(in: other).isEmpty)
    }

    @Test func unreadableFileGivesAnEmptyStoreThatCanBeSavedAgain() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = ReviewCommentStore(fileURL: file)
        #expect(store.comments(in: root).isEmpty)
        store.add(comment("a.swift", 1), in: root)
        store.saveNow()
        #expect(ReviewCommentStore(fileURL: file).comments(in: root).count == 1)
    }

    @Test func withoutAFileNothingIsWritten() {
        let store = ReviewCommentStore()
        store.add(comment("a.swift", 1), in: root)
        store.saveNow()
        #expect(store.comments(in: root).count == 1)
    }
}

struct ReviewPromptTests {
    @Test func groupsByFileAndNamesPathAndLine() {
        let text = ReviewPrompt.text(for: [
            comment("Sources/A.swift", 12, code: "    let x = compute()", "Rename this."),
            comment("Sources/B.swift", 4, code: "foo()", "Why?"),
            comment("Sources/A.swift", 30, side: .old, code: "oldCall()", "Keep this call."),
        ])
        #expect(text == """
        Please address these review comments on your changes:

        Sources/A.swift:12
        `let x = compute()`
        Rename this.

        Sources/A.swift:30 (removed line)
        `oldCall()`
        Keep this call.

        Sources/B.swift:4
        `foo()`
        Why?
        """)
    }

    @Test func singleCommentStagedAndMultiLineBody() {
        let text = ReviewPrompt.text(for: [comment("a.py", 2, staged: true, code: "x = 1\t", "\n  First line.  \r\n\n  Indented second.\n\n")])
        #expect(text == """
        Please address this review comment on your changes:

        a.py:2 (staged version)
        `x = 1`
        First line.

          Indented second.
        """)
        #expect(!text.hasSuffix("\n"))
    }

    @Test func removedAndStagedNotesCombine() {
        let text = ReviewPrompt.text(for: [comment("a", 7, side: .old, staged: true)])
        #expect(text.contains("a:7 (removed line, staged version)\n"))
    }

    @Test func truncatesLongLines() {
        let long = String(repeating: "x", count: 500)
        let quote = ReviewPrompt.quote(long)
        #expect(quote == "`" + String(repeating: "x", count: ReviewPrompt.maximumQuoteLength) + "...`")
    }

    @Test func quotesBackticksAndBlankLines() {
        #expect(ReviewPrompt.quote("let s = `a`") == "`` let s = `a` ``")
        #expect(ReviewPrompt.quote("x ``y`` z") == "```x ``y`` z```")
        #expect(ReviewPrompt.quote("   \t") == "(blank line)")
    }

    @Test func emptyInputGivesEmptyText() {
        #expect(ReviewPrompt.text(for: []) == "")
    }

    @Test func neverContainsLongDashes() {
        let text = ReviewPrompt.text(for: [comment("a", 1, side: .old, staged: true), comment("b", 2, code: "", "")])
        #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
    }
}
