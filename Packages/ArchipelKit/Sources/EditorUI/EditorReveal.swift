import AppKit

/// Scrolls the editor of a given file to a line, without taking the keyboard. The host calls this
/// when a file is opened from a link in the terminal (`Foo.swift:1248:5`), where focus should stay
/// in the terminal.
///
/// Like `EditorFocus`, the request is kept for a moment because the editor may not exist yet: the
/// file loads asynchronously and only then is its text view created. An already open editor answers
/// through the notification instead.
///
/// A Markdown file shown as rendered preview has no code editor, so the request just expires.
@MainActor
public enum EditorReveal {
    struct Target: Equatable {
        var line: Int
        var column: Int?
    }

    private static var pending: (url: URL, target: Target, deadline: ContinuousClock.Instant)?
    static let requested = Notification.Name("EditorReveal.requested")

    /// `line` and `column` are 1-based, as compilers and terminals print them.
    public static func request(_ url: URL, line: Int, column: Int?) {
        pending = (url.standardizedFileURL.resolvingSymlinksInPath(), Target(line: line, column: column), .now + .seconds(2))
        NotificationCenter.default.post(name: requested, object: nil)
    }

    /// Hands out the target only once, so a second editor of the same file opened later doesn't jump too.
    static func claim(_ url: URL) -> (line: Int, column: Int?)? {
        guard let pending, pending.url == url.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        self.pending = nil
        guard ContinuousClock.now < pending.deadline else { return nil }
        return (pending.target.line, pending.target.column)
    }

    /// UTF-16 offset for a 1-based line and column. Links come from compiler output that can be stale
    /// after edits, so a line past the end lands on the last line and a column past the end on the
    /// end of its line rather than failing.
    static func offset(line: Int, column: Int?, in text: String, index: LineIndex) -> Int {
        let row = min(max(line, 1), index.lineCount) - 1
        let start = index.starts[row]
        var end = row + 1 < index.lineCount ? index.starts[row + 1] : index.length
        // Stop in front of the line break, which is two units for CRLF.
        let string = text as NSString
        while end > start, isTerminator(string.character(at: end - 1)) { end -= 1 }
        let offset = max((column ?? 1) - 1, 0)
        return min(start + offset, end)
    }

    private static func isTerminator(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x85 || unit == 0x2028 || unit == 0x2029
    }
}
