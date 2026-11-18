import Foundation

/// A stretch of changes with its surrounding context, the way `git diff` would have printed it as
/// one hunk. The diff view loads the whole file as a single hunk, so these are recomputed here.
struct DiffHunk: Equatable, Sendable {
    /// Rows of `DiffDocument.unified`, context included.
    var rows: Range<Int>
    /// The first changed row's line on each side; at least one is set. Lets either presentation
    /// find the row that carries the drag handle.
    var firstOld: Int?
    var firstNew: Int?
}

enum DiffHunks {
    static let context = 3

    static func hunks(in document: DiffDocument, context: Int = DiffHunks.context) -> [DiffHunk] {
        let rows = document.unified
        var hunks: [DiffHunk] = []
        var start = 0
        var end = 0
        var lead: DiffRow?

        for (index, row) in rows.enumerated() where row.isChange {
            let windowStart = max(0, index - context)
            if lead != nil, windowStart <= end {
                end = min(rows.count, index + context + 1)
                continue
            }
            if let lead { hunks.append(hunk(start..<end, lead: lead)) }
            lead = row
            start = windowStart
            end = min(rows.count, index + context + 1)
        }
        if let lead { hunks.append(hunk(start..<end, lead: lead)) }
        return hunks
    }

    private static func hunk(_ rows: Range<Int>, lead: DiffRow) -> DiffHunk {
        DiffHunk(rows: rows, firstOld: lead.old, firstNew: lead.new)
    }

    /// Index of the row in `rows` (whichever presentation) that starts each hunk, mapped to the hunk's index.
    ///
    /// One pass over the rows for all hunks together. Searching per hunk made this hunks times rows,
    /// and it runs again whenever the presentation is toggled.
    static func leadRows(of hunks: [DiffHunk], in rows: [DiffRow]) -> [Int: Int] {
        // Line on the old side, or on the new side for a hunk that starts with an addition, to the
        // hunks still waiting for the first row that shows it.
        var waitingForOld: [Int: [Int]] = [:]
        var waitingForNew: [Int: [Int]] = [:]
        for (hunkIndex, hunk) in hunks.enumerated() {
            if let old = hunk.firstOld {
                waitingForOld[old, default: []].append(hunkIndex)
            } else if let new = hunk.firstNew {
                waitingForNew[new, default: []].append(hunkIndex)
            }
        }

        var result: [Int: Int] = [:]
        for (index, row) in rows.enumerated() {
            if waitingForOld.isEmpty, waitingForNew.isEmpty { break }
            let found = if let old = row.old {
                waitingForOld.removeValue(forKey: old)
            } else if let new = row.new {
                waitingForNew.removeValue(forKey: new)
            } else {
                [Int]?.none
            }
            if let last = found?.last { result[index] = last }
        }
        return result
    }

    /// `path:start-end`, then the hunk as a fenced diff block. The range is on the new side, or the
    /// old side when the hunk adds nothing: pure deletions have no new lines to point at.
    static func text(path: String, hunk: DiffHunk, in document: DiffDocument) -> String {
        var lines: [String] = []
        var newNumbers: [Int] = []
        var oldNumbers: [Int] = []
        for row in document.unified[hunk.rows] {
            switch row.kind {
            case .removed:
                guard let old = row.old else { continue }
                lines.append("-" + document.old.lines[old])
                oldNumbers.append(document.old.numbers[old])
            case .added:
                guard let new = row.new else { continue }
                lines.append("+" + document.new.lines[new])
                newNumbers.append(document.new.numbers[new])
            case .context, .modified:
                guard let new = row.new else { continue }
                lines.append(" " + document.new.lines[new])
                newNumbers.append(document.new.numbers[new])
                if let old = row.old { oldNumbers.append(document.old.numbers[old]) }
            }
        }
        let numbers = lines.contains { $0.hasPrefix("+") } ? newNumbers : oldNumbers
        let range = "\(numbers.min() ?? 0)-\(numbers.max() ?? 0)"
        // A hunk that itself contains a code fence must not close ours early.
        let longestRun = lines.map(backtickRun).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(path):\(range)\n\(fence)diff\n\(lines.joined(separator: "\n"))\n\(fence)"
    }

    private static func backtickRun(in line: String) -> Int {
        var longest = 0
        var current = 0
        for character in line {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
