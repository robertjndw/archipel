import Foundation
import GitKit

enum LineEnding: Equatable, Sendable {
    case lf, crlf, mixed

    var label: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .mixed: "Mixed"
        }
    }
}

/// One side of a comparison, rebuilt from the whole-file hunk git printed.
struct DiffSide: Equatable, Sendable {
    /// Display text of every line, without line terminators.
    var lines: [String] = []
    /// One-based line number of each entry in `lines`.
    var numbers: [Int] = []
    var missingNewlineAtEnd = false
    var lineEnding: LineEnding?
    private var crlfCount = 0

    /// What gets highlighted: the lines joined with `\n`, with each line's UTF-16 start offset.
    var text: String { lines.joined(separator: "\n") }

    func lineOffsets() -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            offsets.append(offset)
            offset += line.utf16.count + 1
        }
        return offsets
    }

    fileprivate mutating func append(_ line: GitDiffLine, number: Int) -> Int {
        var text = line.text
        if text.hasSuffix("\r") {
            text.removeLast()
            crlfCount += 1
        }
        lines.append(text)
        numbers.append(number)
        if !line.hasNewline { missingNewlineAtEnd = true }
        return lines.count - 1
    }

    fileprivate mutating func finish() {
        let terminated = lines.count - (missingNewlineAtEnd ? 1 : 0)
        guard terminated > 0 else { return }
        lineEnding = crlfCount == 0 ? .lf : crlfCount >= terminated ? .crlf : .mixed
    }
}

struct DiffRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case context, removed, added, modified
    }

    var kind: Kind
    var old: Int?
    var new: Int?
    /// UTF-16 range within the line that actually changed, for modified pairs.
    var oldEmphasis: Range<Int>?
    var newEmphasis: Range<Int>?

    var isChange: Bool { kind != .context }
}

/// Aligned rows for both presentations of one file's diff.
struct DiffDocument: Equatable, Sendable {
    var old = DiffSide()
    var new = DiffSide()
    /// Removed and added lines paired up in order, the rest padded with filler on the other side.
    var sideBySide: [DiffRow] = []
    /// Git's own order: each run of removals followed by its additions.
    var unified: [DiffRow] = []
    var additions = 0
    var deletions = 0

    init(diff: GitFileDiff) {
        for hunk in diff.hunks {
            var oldNumber = hunk.oldStart
            var newNumber = hunk.newStart
            var removed: [Int] = []
            var added: [Int] = []

            func flushChanges() {
                pairChanges(removed: removed, added: added)
                removed.removeAll()
                added.removeAll()
            }

            for line in hunk.lines {
                switch line.kind {
                case .context:
                    flushChanges()
                    let oldIndex = old.append(line, number: oldNumber)
                    let newIndex = new.append(line, number: newNumber)
                    oldNumber += 1
                    newNumber += 1
                    let row = DiffRow(kind: .context, old: oldIndex, new: newIndex)
                    sideBySide.append(row)
                    unified.append(row)
                case .removed:
                    // A removal after additions starts a new change group.
                    if !added.isEmpty { flushChanges() }
                    removed.append(old.append(line, number: oldNumber))
                    oldNumber += 1
                case .added:
                    added.append(new.append(line, number: newNumber))
                    newNumber += 1
                }
            }
            flushChanges()
        }
        old.finish()
        new.finish()
    }

    private mutating func pairChanges(removed: [Int], added: [Int]) {
        guard !removed.isEmpty || !added.isEmpty else { return }
        deletions += removed.count
        additions += added.count
        var unifiedRemoved: [DiffRow] = []
        var unifiedAdded: [DiffRow] = []

        for index in 0..<max(removed.count, added.count) {
            let oldIndex = index < removed.count ? removed[index] : nil
            let newIndex = index < added.count ? added[index] : nil
            var row = DiffRow(kind: .modified, old: oldIndex, new: newIndex)
            if let oldIndex, let newIndex {
                (row.oldEmphasis, row.newEmphasis) = Self.emphasis(old.lines[oldIndex], new.lines[newIndex])
            } else {
                row.kind = oldIndex == nil ? .added : .removed
            }
            sideBySide.append(row)
            if let oldIndex {
                unifiedRemoved.append(DiffRow(kind: .removed, old: oldIndex, oldEmphasis: row.oldEmphasis))
            }
            if let newIndex {
                unifiedAdded.append(DiffRow(kind: .added, new: newIndex, newEmphasis: row.newEmphasis))
            }
        }
        unified += unifiedRemoved + unifiedAdded
    }

    /// Above this share of a line's content changed on both sides, the emphasis covers nearly the
    /// whole line and only adds noise.
    static let maximumEmphasisShare = 0.6

    /// The changed middle of a modified pair: everything between the longest common prefix and suffix,
    /// trimmed on grapheme boundaries. Nil when the lines share nothing, or little more than their
    /// indentation and a closing brace, since emphasising the whole line again would only add noise.
    static func emphasis(_ old: String, _ new: String) -> (Range<Int>?, Range<Int>?) {
        if old == new { return (nil, nil) }
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        var prefix = 0
        while prefix < oldCharacters.count, prefix < newCharacters.count, oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldCharacters.count - prefix, suffix < newCharacters.count - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix] == newCharacters[newCharacters.count - 1 - suffix] {
            suffix += 1
        }
        if prefix == 0 && suffix == 0 { return (nil, nil) }

        /// How much of the line's content, without its surrounding whitespace, is in the middle.
        func changedShare(_ characters: [Character]) -> Double {
            let content = characters.count
                - characters.prefix { $0.isWhitespace }.count
                - characters.reversed().prefix { $0.isWhitespace }.count
            return content > 0 ? Double(characters.count - prefix - suffix) / Double(content) : 1
        }
        if changedShare(oldCharacters) > maximumEmphasisShare, changedShare(newCharacters) > maximumEmphasisShare {
            return (nil, nil)
        }

        func utf16Range(_ characters: [Character]) -> Range<Int>? {
            let start = characters[..<prefix].reduce(0) { $0 + $1.utf16.count }
            let length = characters[prefix..<(characters.count - suffix)].reduce(0) { $0 + $1.utf16.count }
            return length > 0 ? start..<(start + length) : nil
        }
        return (utf16Range(oldCharacters), utf16Range(newCharacters))
    }
}

enum DiffDisplayItem: Equatable, Sendable {
    case row(Int)
    /// A run of unchanged rows shown as one expandable line.
    case fold(Range<Int>)
}

enum DiffFolding {
    /// Keeps `context` unchanged rows around every change and folds longer unchanged runs.
    /// Runs shorter than `minimumFold` stay visible: a fold that hides two lines saves nothing.
    /// `keeping` names rows that stay visible whatever the rule says, such as ones the user unfolded.
    static func items(for rows: [DiffRow], context: Int = 3, minimumFold: Int = 4, keeping: Set<Int> = []) -> [DiffDisplayItem] {
        var visible = [Bool](repeating: false, count: rows.count)
        for index in keeping where visible.indices.contains(index) { visible[index] = true }
        for (index, row) in rows.enumerated() where row.isChange {
            for neighbour in max(0, index - context)...min(rows.count - 1, index + context) {
                visible[neighbour] = true
            }
        }

        var items: [DiffDisplayItem] = []
        var index = 0
        while index < rows.count {
            if visible[index] {
                items.append(.row(index))
                index += 1
                continue
            }
            var end = index
            while end < rows.count, !visible[end] { end += 1 }
            if end - index >= minimumFold {
                items.append(.fold(index..<end))
            } else {
                items += (index..<end).map(DiffDisplayItem.row)
            }
            index = end
        }
        return items
    }

    static func allRows(_ rows: [DiffRow]) -> [DiffDisplayItem] {
        rows.indices.map(DiffDisplayItem.row)
    }

    static func expanding(_ items: [DiffDisplayItem], at index: Int) -> [DiffDisplayItem] {
        guard items.indices.contains(index), case .fold(let range) = items[index] else { return items }
        var items = items
        items.replaceSubrange(index...index, with: range.map(DiffDisplayItem.row))
        return items
    }

    // MARK: Across refreshes

    /// The unchanged lines the user has unfolded, by their place on the old side. The old side is the
    /// index or HEAD, which stays put while an agent rewrites the working tree, so these still name
    /// the same lines in the next version of the diff.
    static func unfoldedLines(_ items: [DiffDisplayItem], rows: [DiffRow], document: DiffDocument) -> Set<DiffUnchangedLine> {
        let shownByDefault = Set(Self.items(for: rows).compactMap(\.row))
        var lines: Set<DiffUnchangedLine> = []
        for item in items {
            guard let rowIndex = item.row, !shownByDefault.contains(rowIndex),
                  let line = DiffUnchangedLine(rows[rowIndex], in: document) else { continue }
            lines.insert(line)
        }
        return lines
    }

    /// The rows of `document` that show one of `lines`, for `items(for:keeping:)`.
    static func rows(showing lines: Set<DiffUnchangedLine>, in rows: [DiffRow], document: DiffDocument) -> Set<Int> {
        guard !lines.isEmpty else { return [] }
        return Set(rows.indices.filter { DiffUnchangedLine(rows[$0], in: document).map(lines.contains) ?? false })
    }

    /// What sits at a display item, in terms that outlive the layout: a line number on the old side
    /// when the row has one, since that side stays put, else on the new side.
    static func anchor(at item: Int, in items: [DiffDisplayItem], rows: [DiffRow], document: DiffDocument) -> DiffLineAnchor? {
        guard items.indices.contains(item) else { return nil }
        let rowIndex = switch items[item] {
        case .row(let rowIndex): rowIndex
        case .fold(let range): range.lowerBound
        }
        let row = rows[rowIndex]
        if let old = row.old { return DiffLineAnchor(side: .old, line: document.old.numbers[old]) }
        if let new = row.new { return DiffLineAnchor(side: .new, line: document.new.numbers[new]) }
        return nil
    }

    /// The display item that shows `anchor`, or the fold that hides it.
    static func item(showing anchor: DiffLineAnchor, in items: [DiffDisplayItem], rows: [DiffRow], document: DiffDocument) -> Int? {
        func shows(_ rowIndex: Int) -> Bool {
            let row = rows[rowIndex]
            switch anchor.side {
            case .old: return row.old.map { document.old.numbers[$0] == anchor.line } ?? false
            case .new: return row.old == nil && row.new.map { document.new.numbers[$0] == anchor.line } ?? false
            }
        }
        return items.firstIndex { item in
            switch item {
            case .row(let rowIndex): shows(rowIndex)
            case .fold(let range): range.contains(where: shows)
            }
        }
    }
}

/// An unchanged line, by its number and text on the old side.
struct DiffUnchangedLine: Hashable, Sendable {
    var oldLine: Int
    var text: String

    init?(_ row: DiffRow, in document: DiffDocument) {
        guard row.kind == .context, let old = row.old else { return nil }
        oldLine = document.old.numbers[old]
        text = document.old.lines[old]
    }
}

extension DiffDisplayItem {
    var row: Int? {
        if case .row(let index) = self { index } else { nil }
    }
}
