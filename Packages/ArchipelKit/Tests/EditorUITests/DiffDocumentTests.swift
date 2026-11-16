import GitKit
import Testing
@testable import EditorUI

struct DiffDocumentTests {
    private func hunk(_ lines: [GitDiffLine]) -> GitFileDiff {
        let old = lines.filter { $0.kind != .added }.count
        let new = lines.filter { $0.kind != .removed }.count
        return GitFileDiff(oldPath: "a", newPath: "a", status: .modified, hunks: [
            GitDiffHunk(oldStart: old == 0 ? 0 : 1, oldCount: old, newStart: new == 0 ? 0 : 1, newCount: new, lines: lines),
        ])
    }

    @Test func pairsChangesAndPadsTheShorterSide() {
        let document = DiffDocument(diff: hunk([
            GitDiffLine(.context, "a"),
            GitDiffLine(.removed, "b"),
            GitDiffLine(.removed, "c"),
            GitDiffLine(.added, "B"),
            GitDiffLine(.context, "d"),
            GitDiffLine(.added, "e"),
        ]))
        #expect(document.old.lines == ["a", "b", "c", "d"])
        #expect(document.new.lines == ["a", "B", "d", "e"])
        #expect(document.old.numbers == [1, 2, 3, 4])
        #expect(document.new.numbers == [1, 2, 3, 4])
        #expect(document.sideBySide.map(\.kind) == [.context, .modified, .removed, .context, .added])
        #expect(document.sideBySide.map(\.old) == [0, 1, 2, 3, nil])
        #expect(document.sideBySide.map(\.new) == [0, 1, nil, 2, 3])
        #expect(document.unified.map(\.kind) == [.context, .removed, .removed, .added, .context, .added])
        #expect(document.additions == 2)
        #expect(document.deletions == 2)
    }

    @Test func newAndDeletedFilesAreOneSided() {
        let added = DiffDocument(diff: hunk([GitDiffLine(.added, "x"), GitDiffLine(.added, "y")]))
        #expect(added.old.lines.isEmpty)
        #expect(added.sideBySide.allSatisfy { $0.kind == .added && $0.old == nil })
        let deleted = DiffDocument(diff: hunk([GitDiffLine(.removed, "x")]))
        #expect(deleted.sideBySide == [DiffRow(kind: .removed, old: 0)])
    }

    @Test func stripsCarriageReturnsAndRecordsLineEndings() {
        let document = DiffDocument(diff: hunk([
            GitDiffLine(.removed, "a"),
            GitDiffLine(.removed, "b", hasNewline: false),
            GitDiffLine(.added, "a\r"),
            GitDiffLine(.added, "b\r"),
        ]))
        #expect(document.new.lines == ["a", "b"])
        #expect(document.old.lineEnding == .lf)
        #expect(document.new.lineEnding == .crlf)
        #expect(document.old.missingNewlineAtEnd)
        #expect(!document.new.missingNewlineAtEnd)
        // Only the line ending differs, so there is nothing to emphasise.
        #expect(document.sideBySide[0].oldEmphasis == nil)
    }

    @Test func emphasisCoversTheChangedMiddle() {
        let (old, new) = DiffDocument.emphasis("sleep(3))", "sleep(5)) // slower")
        #expect(old == 6..<9)
        #expect(new == 6..<19)
        let (insertedOld, insertedNew) = DiffDocument.emphasis("ab", "a\u{1F600}b")
        #expect(insertedOld == nil)
        #expect(insertedNew == 1..<3)
        #expect(DiffDocument.emphasis("abc", "xyz") == (nil, nil))
    }

    @Test func foldsLongUnchangedRuns() {
        var lines = (1...20).map { GitDiffLine(.context, "\($0)") }
        lines.insert(GitDiffLine(.added, "new"), at: 10)
        let document = DiffDocument(diff: hunk(lines))
        let items = DiffFolding.items(for: document.sideBySide, context: 3, minimumFold: 4)
        #expect(items.first == .fold(0..<7))
        #expect(items.last == .fold(14..<21))
        #expect(items.count == 9)

        let expanded = DiffFolding.expanding(items, at: 0)
        #expect(expanded.count == 15)
        #expect(expanded.first == .row(0))
    }

    @Test func shortUnchangedRunsStayVisible() {
        var lines = (1...8).map { GitDiffLine(.context, "\($0)") }
        lines.insert(GitDiffLine(.removed, "gone"), at: 4)
        let items = DiffFolding.items(for: DiffDocument(diff: hunk(lines)).sideBySide, context: 3, minimumFold: 4)
        #expect(items.allSatisfy { if case .row = $0 { true } else { false } })
    }
}
