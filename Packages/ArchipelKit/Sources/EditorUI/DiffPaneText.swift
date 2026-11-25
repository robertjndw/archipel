import Foundation

/// A place in the text of one diff pane: a row of the layout and a UTF-16 offset into the line that
/// row shows in the pane. Rows rather than display items, so expanding a fold leaves a selection
/// where it was.
struct DiffTextPosition: Comparable, Hashable {
    var row: Int
    var column: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// The text a pane shows, for copying a selection and for VoiceOver. Kept apart from the view so it
/// can be tested.
@MainActor
enum DiffPaneText {
    /// The line a row shows in the pane, or nil for filler.
    static func line(of rowIndex: Int, in layout: DiffLayout, role: DiffPaneRole) -> String? {
        guard let (index, isOld) = layout.line(for: layout.rows[rowIndex], role: role) else { return nil }
        return layout.side(isOld).side.lines[index]
    }

    /// The selected text as it reads in the pane, one line per row. Rows folded away count as
    /// selected too, since what is copied is the file, not the screen; filler rows add nothing.
    static func text(from start: DiffTextPosition, to end: DiffTextPosition, in layout: DiffLayout, role: DiffPaneRole) -> String {
        guard start < end, layout.rows.indices.contains(start.row), layout.rows.indices.contains(end.row) else { return "" }
        var lines: [String] = []
        for row in start.row...end.row {
            guard let line = line(of: row, in: layout, role: role) else { continue }
            let units = line.utf16
            let from = row == start.row ? min(start.column, units.count) : 0
            let to = row == end.row ? min(end.column, units.count) : units.count
            let slice = units[units.index(units.startIndex, offsetBy: from)..<units.index(units.startIndex, offsetBy: max(from, to))]
            lines.append(String(slice) ?? String(decoding: Array(slice), as: UTF16.self))
        }
        return lines.joined(separator: "\n")
    }

    /// The position after the last character of the pane, for Select All.
    static func end(of layout: DiffLayout, role: DiffPaneRole) -> DiffTextPosition? {
        guard let last = layout.rows.indices.last else { return nil }
        return DiffTextPosition(row: last, column: line(of: last, in: layout, role: role)?.utf16.count ?? 0)
    }

    /// A selection made in `old`, placed on the same lines of `new`, or nil when any selected line
    /// is gone or reads differently. Lines are matched by side, number and text; an unchanged line
    /// by its old-side number, which stays put while an agent rewrites the working tree. A selection
    /// ending on filler is first pulled in to the lines around it, which copy the same text.
    static func carry(
        _ selection: (anchor: DiffTextPosition, head: DiffTextPosition),
        from old: DiffLayout,
        to new: DiffLayout,
        role: DiffPaneRole
    ) -> (anchor: DiffTextPosition, head: DiffTextPosition)? {
        let forward = selection.anchor <= selection.head
        var start = min(selection.anchor, selection.head)
        var end = max(selection.anchor, selection.head)
        guard old.rows.indices.contains(start.row), old.rows.indices.contains(end.row) else { return nil }
        while start.row <= end.row, line(of: start.row, in: old, role: role) == nil {
            start = DiffTextPosition(row: start.row + 1, column: 0)
        }
        while end.row >= start.row, line(of: end.row, in: old, role: role) == nil {
            end = DiffTextPosition(row: end.row - 1, column: Int.max)
        }
        guard start.row <= end.row, let startKey = key(of: start.row, in: old, role: role),
              let endKey = key(of: end.row, in: old, role: role) else { return nil }
        end.column = min(end.column, line(of: end.row, in: old, role: role)?.utf16.count ?? 0)

        var startRow: Int?
        var endRow: Int?
        for rowIndex in new.rows.indices where startRow == nil || endRow == nil {
            guard let key = key(of: rowIndex, in: new, role: role) else { continue }
            if startRow == nil, key == startKey { startRow = rowIndex }
            if key == endKey { endRow = rowIndex }
        }
        guard let startRow, let endRow, startRow <= endRow else { return nil }
        let newStart = DiffTextPosition(row: startRow, column: start.column)
        let newEnd = DiffTextPosition(row: endRow, column: end.column)
        // Lines added or removed between the ends would change what the selection holds.
        guard text(from: start, to: end, in: old, role: role) == text(from: newStart, to: newEnd, in: new, role: role) else { return nil }
        return forward ? (newStart, newEnd) : (newEnd, newStart)
    }

    private struct LineKey: Hashable {
        var isOld: Bool
        var number: Int
        var text: String
    }

    private static func key(of rowIndex: Int, in layout: DiffLayout, role: DiffPaneRole) -> LineKey? {
        let row = layout.rows[rowIndex]
        guard let (index, isOld) = layout.line(for: row, role: role) else { return nil }
        let side = layout.side(isOld).side
        if row.kind == .context, let old = row.old {
            return LineKey(isOld: true, number: layout.document.old.numbers[old], text: side.lines[index])
        }
        return LineKey(isOld: isOld, number: side.numbers[index], text: side.lines[index])
    }

    /// The word around a UTF-16 column, for a double click: a run of letters, digits and
    /// underscores, or else the single character there.
    static func word(in line: String, at column: Int) -> Range<Int> {
        let units = Array(line.utf16)
        guard !units.isEmpty else { return 0..<0 }
        let column = min(max(0, column), units.count - 1)
        func isWordUnit(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return true }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
        guard isWordUnit(units[column]) else { return column..<(column + 1) }
        var lower = column
        while lower > 0, isWordUnit(units[lower - 1]) { lower -= 1 }
        var upper = column + 1
        while upper < units.count, isWordUnit(units[upper]) { upper += 1 }
        return lower..<upper
    }

    /// What VoiceOver reads: one line per display item, changed lines said to be added or removed,
    /// and a fold as the number of lines it hides.
    static func accessible(_ layout: DiffLayout, role: DiffPaneRole) -> DiffAccessibleText {
        var lines: [String] = []
        var prefixes: [Int] = []
        lines.reserveCapacity(layout.items.count)
        for item in layout.items {
            switch item {
            case .fold(let range):
                let format = range.count == 1 ? String(localized: "%lld unchanged line hidden") : String(localized: "%lld unchanged lines hidden")
                lines.append(String(format: format, range.count))
                prefixes.append(0)
            case .row(let rowIndex):
                let row = layout.rows[rowIndex]
                guard let (index, isOld) = layout.line(for: row, role: role) else {
                    // Filler: the other side has a line here and this one does not.
                    lines.append("")
                    prefixes.append(0)
                    continue
                }
                var text = layout.side(isOld).side.lines[index]
                if text.utf16.count > DiffLineRenderer.maximumDrawnLength { text = String(text.prefix(DiffLineRenderer.maximumDrawnLength)) }
                let prefix = row.kind == .context ? "" : isOld ? String(localized: "Removed: ") : String(localized: "Added: ")
                lines.append(prefix + text)
                prefixes.append(prefix.utf16.count)
            }
        }
        return DiffAccessibleText(lines: lines, prefixLengths: prefixes)
    }
}

/// A pane's text for accessibility, with where each display item's line starts in it.
struct DiffAccessibleText {
    let string: String
    /// UTF-16 offset of each display item's line.
    let lineStarts: [Int]
    /// Length of the "Added: " or "Removed: " before a line's own text.
    let prefixLengths: [Int]

    init(lines: [String], prefixLengths: [Int]) {
        string = lines.joined(separator: "\n")
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        lineStarts = starts
        self.prefixLengths = prefixLengths
    }

    var length: Int { string.utf16.count }

    func line(containing offset: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// A line's range, including the newline after it except on the last line.
    func range(ofLine line: Int) -> NSRange {
        guard lineStarts.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: lineStarts[line], length: end - lineStarts[line])
    }

    /// Where a column of an item's line falls in the string.
    func offset(item: Int, column: Int) -> Int {
        guard lineStarts.indices.contains(item) else { return length }
        let lineEnd = item + 1 < lineStarts.count ? lineStarts[item + 1] - 1 : length
        return min(lineStarts[item] + prefixLengths[item] + column, lineEnd)
    }
}
