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

struct DiffCommentAnchoringTests {
    /// Old: a b c d. New: a B d e. Rows side by side: a | b/B | c/- | d | -/e.
    private let document = DiffDocument(diff: GitFileDiff(oldPath: "f", newPath: "f", status: .modified, hunks: [
        GitDiffHunk(oldStart: 10, oldCount: 4, newStart: 10, newCount: 4, lines: [
            GitDiffLine(.context, "a"),
            GitDiffLine(.removed, "b"),
            GitDiffLine(.removed, "c"),
            GitDiffLine(.added, "B"),
            GitDiffLine(.context, "d"),
            GitDiffLine(.added, "e"),
        ]),
    ]))

    private func anchors(_ rows: [DiffRow], _ role: DiffPaneRole) -> [String?] {
        rows.map { row in
            DiffCommentAnchoring.anchor(for: row, role: role, in: document).map { "\($0.anchor.side.rawValue)\($0.anchor.line) \($0.text)" }
        }
    }

    @Test func sideBySideOldPaneAnchorsContextOnTheNewSide() {
        #expect(anchors(document.sideBySide, .old) == ["new10 a", "old11 b", "old12 c", "new12 d", nil])
    }

    @Test func sideBySideNewPane() {
        #expect(anchors(document.sideBySide, .new) == ["new10 a", "new11 B", nil, "new12 d", "new13 e"])
    }

    @Test func unifiedMapsRemovedRowsToTheOldSide() {
        #expect(anchors(document.unified, .unified) == ["new10 a", "old11 b", "old12 c", "new11 B", "new12 d", "new13 e"])
    }

    @Test func marksOnlyVisibleRowsWithComments() {
        let anchors: Set = [DiffLineAnchor(side: .new, line: 12), DiffLineAnchor(side: .old, line: 11), DiffLineAnchor(side: .new, line: 99)]
        let items = DiffFolding.allRows(document.sideBySide)
        #expect(DiffCommentAnchoring.markedItems(items, rows: document.sideBySide, role: .old, document: document, anchors: anchors) == [1, 3])
        #expect(DiffCommentAnchoring.markedItems(items, rows: document.sideBySide, role: .new, document: document, anchors: anchors) == [3])
        #expect(DiffCommentAnchoring.markedItems(items, rows: document.sideBySide, role: .new, document: document, anchors: []) == [])
    }

    @Test func commentsInsideAFoldHaveNoMarker() {
        var lines = (1...20).map { GitDiffLine(.context, "\($0)") }
        lines.insert(GitDiffLine(.added, "new"), at: 10)
        let document = DiffDocument(diff: GitFileDiff(oldPath: "f", newPath: "f", status: .modified, hunks: [
            GitDiffHunk(oldStart: 1, oldCount: 20, newStart: 1, newCount: 21, lines: lines),
        ]))
        let items = DiffFolding.items(for: document.unified)
        // Line 2 is folded away, line 11 is the addition, and line 8 is visible context.
        let anchors = Set([2, 8, 11].map { DiffLineAnchor(side: .new, line: $0) })
        let marked = DiffCommentAnchoring.markedItems(items, rows: document.unified, role: .unified, document: document, anchors: anchors)
        #expect(marked.sorted().map { items[$0] } == [.row(7), .row(10)])
        let expanded = DiffFolding.expanding(items, at: 0)
        #expect(DiffCommentAnchoring.markedItems(expanded, rows: document.unified, role: .unified, document: document, anchors: anchors).count == 3)
    }
}
