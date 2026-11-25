import Foundation

/// The line a comment is attached to: a number on one side of the change.
struct DiffLineAnchor: Hashable, Sendable {
    var side: ReviewComment.Side
    var line: Int
}

extension ReviewComment {
    var anchor: DiffLineAnchor {
        DiffLineAnchor(side: side, line: line)
    }
}

/// Maps between diff rows and comment anchors, kept apart from the views so it can be tested.
enum DiffCommentAnchoring {
    /// The anchor a click on a row in a pane comments on, and the text of that line.
    ///
    /// An unchanged line is always anchored on the new side, even in the left pane of side by side, so
    /// commenting on it from either pane edits the same comment and the prompt numbers it the way the
    /// agent's current file does. Fold and filler rows have no line and give nil.
    static func anchor(for row: DiffRow, role: DiffPaneRole, in document: DiffDocument) -> (anchor: DiffLineAnchor, text: String)? {
        let oldIndex: Int?
        let newIndex: Int?
        switch role {
        case .old:
            guard row.old != nil else { return nil }
            (oldIndex, newIndex) = row.kind == .context ? (nil, row.new) : (row.old, nil)
        case .new:
            (oldIndex, newIndex) = (nil, row.new)
        case .unified:
            (oldIndex, newIndex) = row.kind == .removed ? (row.old, nil) : (nil, row.new)
        }
        if let oldIndex {
            return (DiffLineAnchor(side: .old, line: document.old.numbers[oldIndex]), document.old.lines[oldIndex])
        }
        if let newIndex {
            return (DiffLineAnchor(side: .new, line: document.new.numbers[newIndex]), document.new.lines[newIndex])
        }
        return nil
    }

    /// Display items of a pane that show a commented line. Computed once per change of layout, folds
    /// or comments, so drawing only does a set lookup per visible row. A comment whose line sits in a
    /// collapsed fold, or no longer exists, has no item.
    static func markedItems(
        _ items: [DiffDisplayItem],
        rows: [DiffRow],
        role: DiffPaneRole,
        document: DiffDocument,
        anchors: Set<DiffLineAnchor>
    ) -> Set<Int> {
        guard !anchors.isEmpty else { return [] }
        var marked: Set<Int> = []
        for (index, item) in items.enumerated() {
            guard case .row(let rowIndex) = item,
                  let anchor = anchor(for: rows[rowIndex], role: role, in: document)?.anchor,
                  anchors.contains(anchor) else { continue }
            marked.insert(index)
        }
        return marked
    }

    /// Display items whose comment was made on a line that read differently. The comment stays on
    /// its line number, so this is the only hint that the agent has moved the code under it.
    static func staleItems(
        _ items: [DiffDisplayItem],
        rows: [DiffRow],
        role: DiffPaneRole,
        document: DiffDocument,
        comments: [ReviewComment]
    ) -> Set<Int> {
        guard !comments.isEmpty else { return [] }
        var snapshots: [DiffLineAnchor: [String]] = [:]
        for comment in comments { snapshots[comment.anchor, default: []].append(comment.lineText) }
        var stale: Set<Int> = []
        for (index, item) in items.enumerated() {
            guard case .row(let rowIndex) = item,
                  let (anchor, text) = anchor(for: rows[rowIndex], role: role, in: document),
                  let texts = snapshots[anchor], texts.contains(where: { $0 != text }) else { continue }
            stale.insert(index)
        }
        return stale
    }
}
