import GitKit
import Testing
@testable import EditorUI

struct DiffHunkTests {
    private func document(_ lines: [GitDiffLine]) -> DiffDocument {
        let old = lines.filter { $0.kind != .added }.count
        let new = lines.filter { $0.kind != .removed }.count
        return DiffDocument(diff: GitFileDiff(oldPath: "a", newPath: "a", status: .modified, hunks: [
            GitDiffHunk(oldStart: 1, oldCount: old, newStart: 1, newCount: new, lines: lines),
        ]))
    }

    private func context(_ count: Int) -> [GitDiffLine] {
        (0..<count).map { GitDiffLine(.context, "c\($0)") }
    }

    @Test func distantChangesAreSeparateHunksAndCloseOnesMerge() {
        let far = document(context(2) + [GitDiffLine(.added, "x")] + context(10) + [GitDiffLine(.removed, "y")] + context(1))
        #expect(DiffHunks.hunks(in: far).count == 2)
        let near = document(context(2) + [GitDiffLine(.added, "x")] + context(6) + [GitDiffLine(.removed, "y")] + context(1))
        #expect(DiffHunks.hunks(in: near).count == 1)
        #expect(DiffHunks.hunks(in: document(context(5))).isEmpty)
    }

    @Test func formatsPathRangeAndFencedLines() {
        let doc = document([
            GitDiffLine(.context, "a"),
            GitDiffLine(.removed, "b"),
            GitDiffLine(.added, "B"),
            GitDiffLine(.context, "c"),
        ])
        let hunk = DiffHunks.hunks(in: doc)[0]
        #expect(DiffHunks.text(path: "Sources/x.swift", hunk: hunk, in: doc) == """
        Sources/x.swift:1-3
        ```diff
         a
        -b
        +B
         c
        ```
        """)
    }

    @Test func deletionOnlyHunkUsesOldLineNumbers() {
        let doc = document(context(1) + [GitDiffLine(.removed, "gone")])
        let text = DiffHunks.text(path: "f", hunk: DiffHunks.hunks(in: doc)[0], in: doc)
        #expect(text.hasPrefix("f:1-2\n"))
        #expect(text.contains("-gone"))
    }

    @Test func fenceGrowsPastBackticksInTheHunk() {
        let doc = document([GitDiffLine(.added, "```swift")])
        let text = DiffHunks.text(path: "f", hunk: DiffHunks.hunks(in: doc)[0], in: doc)
        #expect(text == "f:1-1\n````diff\n+```swift\n````")
    }

    @Test func leadRowFollowsThePresentation() {
        let doc = document(context(5) + [GitDiffLine(.removed, "b"), GitDiffLine(.added, "B")] + context(1))
        let hunks = DiffHunks.hunks(in: doc)
        // Paired into one modified row side by side, two rows inline.
        #expect(DiffHunks.leadRows(of: hunks, in: doc.sideBySide) == [5: 0])
        #expect(DiffHunks.leadRows(of: hunks, in: doc.unified) == [5: 0])
    }

    @Test func leadRowsOfManyHunksMatchSearchingForEachOne() {
        // Every way a hunk can start: an addition, a deletion, a replacement, and changes at both ends of the file.
        let lines = [GitDiffLine(.added, "top")] + context(12)
            + [GitDiffLine(.removed, "r")] + context(12)
            + [GitDiffLine(.removed, "m"), GitDiffLine(.added, "M")] + context(12)
            + [GitDiffLine(.added, "a1"), GitDiffLine(.added, "a2")] + context(12)
            + [GitDiffLine(.removed, "end")]
        let doc = document(lines)
        let hunks = DiffHunks.hunks(in: doc)
        #expect(hunks.count == 5)

        for rows in [doc.unified, doc.sideBySide] {
            var expected: [Int: Int] = [:]
            for (hunkIndex, hunk) in hunks.enumerated() {
                let match = rows.firstIndex { row in
                    if let old = hunk.firstOld { return row.old == old }
                    return row.old == nil && row.new == hunk.firstNew
                }
                if let match { expected[match] = hunkIndex }
            }
            #expect(expected.count == 5)
            #expect(DiffHunks.leadRows(of: hunks, in: rows) == expected)
        }
        #expect(DiffHunks.leadRows(of: [], in: doc.unified).isEmpty)
    }
}
