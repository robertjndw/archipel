import Foundation
import GitKit
import Testing
@testable import EditorUI

private func comment(
    _ path: String, _ line: Int, side: ReviewComment.Side = .new, staged: Bool = false, code: String = "code", _ body: String = "fix"
) -> ReviewComment {
    ReviewComment(path: path, staged: staged, side: side, line: line, lineText: code, body: body)
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
