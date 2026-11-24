import Foundation

/// One line of a unified diff.
struct DiffLine: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case context
        case added
        case removed
        /// Unchanged lines left out between two hunks.
        case gap
    }

    var id: Int
    var kind: Kind
    var text: String
}

/// A line-based diff of two texts, for the small edits agents propose. Not a replacement for git:
/// it knows nothing of moves or whitespace, which is fine for showing one edit.
enum LineDiff {
    struct Stats: Equatable, Sendable {
        var added: Int
        var removed: Int
    }

    /// Above this many lines on either side the diff is not computed and the texts are shown as
    /// one removal and one addition. The difference is quadratic in the worst case, and an agent
    /// rewriting a generated file must not stall the transcript.
    static let maximumLines = 4000

    /// The unified diff from `old` to `new`, keeping `context` unchanged lines around each change.
    /// A nil `old` is a new file.
    static func lines(old: String?, new: String, context: Int = 3) -> [DiffLine] {
        trimmed(changes(old: old, new: new), context: context)
    }

    static func stats(old: String?, new: String) -> Stats {
        var stats = Stats(added: 0, removed: 0)
        for change in changes(old: old, new: new) {
            switch change.kind {
            case .added: stats.added += 1
            case .removed: stats.removed += 1
            case .context, .gap: break
            }
        }
        return stats
    }

    /// Lines as an editor counts them: a trailing newline ends the last line, it does not start
    /// another. Splitting on `isNewline` matters because "\r\n" is one Character and would not
    /// match "\n".
    static func splitLines(_ text: String) -> [Substring] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    struct Change {
        var kind: DiffLine.Kind
        var text: Substring
    }

    private static func changes(old: String?, new: String) -> [Change] {
        changesAndPrecision(old: old, new: new).changes
    }

    /// The changes, and whether they are approximate because the texts were too long to compare.
    static func changesAndPrecision(old: String?, new: String) -> (changes: [Change], isApproximate: Bool) {
        let newLines = splitLines(new)
        guard let old else { return (newLines.map { Change(kind: .added, text: $0) }, false) }
        let oldLines = splitLines(old)
        guard oldLines.count <= maximumLines, newLines.count <= maximumLines else {
            return (oldLines.map { Change(kind: .removed, text: $0) } + newLines.map { Change(kind: .added, text: $0) }, true)
        }

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        var result: [Change] = []
        result.reserveCapacity(max(oldLines.count, newLines.count) + removed.count)
        var (oldIndex, newIndex) = (0, 0)
        while oldIndex < oldLines.count || newIndex < newLines.count {
            // Removals first, so a changed line reads as "was, is" the way every diff shows it.
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                result.append(Change(kind: .removed, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                result.append(Change(kind: .added, text: newLines[newIndex]))
                newIndex += 1
            } else if newIndex < newLines.count {
                result.append(Change(kind: .context, text: newLines[newIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return (result, false)
    }

    static func trimmed(_ changes: [Change], context: Int) -> [DiffLine] {
        var keep = [Bool](repeating: false, count: changes.count)
        for (index, change) in changes.enumerated() where change.kind != .context {
            for neighbour in max(0, index - context)...min(changes.count - 1, index + context) {
                keep[neighbour] = true
            }
        }

        var lines: [DiffLine] = []
        var skipped = false
        for (index, change) in changes.enumerated() {
            guard keep[index] else {
                skipped = true
                continue
            }
            // Only between hunks: what was left out before the first one needs no marker.
            if skipped, !lines.isEmpty {
                lines.append(DiffLine(id: lines.count, kind: .gap, text: ""))
            }
            skipped = false
            lines.append(DiffLine(id: lines.count, kind: change.kind, text: String(change.text)))
        }
        return lines
    }
}

/// The end of long command output, which is where the result is.
enum OutputTail {
    struct Result: Equatable {
        var text: String
        var lineCount: Int
        /// Lines left out at the start.
        var hiddenLines: Int
    }

    static func tail(of text: String, maximumLines: Int = 400) -> Result {
        let lines = LineDiff.splitLines(text)
        guard lines.count > maximumLines else {
            return Result(text: lines.joined(separator: "\n"), lineCount: lines.count, hiddenLines: 0)
        }
        return Result(
            text: lines.suffix(maximumLines).joined(separator: "\n"),
            lineCount: maximumLines,
            hiddenLines: lines.count - maximumLines
        )
    }
}
