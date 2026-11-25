import Foundation
import Observation

/// One comment on one line of a diff.
public struct ReviewComment: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// Repo-relative, as DiffViewer receives it.
    public var path: String
    public var staged: Bool
    /// `.old` for a line that only exists before the change, else `.new`.
    public var side: Side
    /// 1-based line number on that side.
    public var line: Int
    /// Snapshot of the commented line, so the prompt stays meaningful after the file moves on.
    public var lineText: String
    public var body: String

    public enum Side: String, Codable, Sendable {
        case old, new
    }

    public init(id: UUID = UUID(), path: String, staged: Bool, side: Side, line: Int, lineText: String, body: String) {
        self.id = id
        self.path = path
        self.staged = staged
        self.side = side
        self.line = line
        self.lineText = lineText
        self.body = body
    }
}

/// Comments of every worktree, kept by the app because a diff view only exists while its tab is selected.
///
/// Comments are anchored to (side, line) and never re-anchored: when the agent rewrites the file the
/// number may point elsewhere, which is why each comment carries a snapshot of the line it was made on.
///
/// With a file the comments survive a relaunch: a review is often written over a while, and losing
/// it to a quit or a crash costs more than the few bytes it takes to keep.
@MainActor @Observable
public final class ReviewCommentStore {
    private var commentsByRoot: [String: [ReviewComment]] = [:] {
        didSet { if commentsByRoot != oldValue { scheduleSave() } }
    }
    /// The batch each worktree sent last. Sending only pastes the prompt into the agent's input, where
    /// an Esc or a dropped paste loses it, so it stays restorable until the next send or until a new
    /// comment shows the review has moved on. Kept in memory only: a relaunch ends that window.
    private var sentByRoot: [String: [ReviewComment]] = [:]
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    static let saveDelay = Duration.milliseconds(400)

    /// What is written to the file. Versioned so a later format can tell what it is reading.
    private struct Archive: Codable {
        var version = 1
        var commentsByRoot: [String: [ReviewComment]]
    }

    /// Without a file nothing is read or written. A file that cannot be read gives an empty store;
    /// it is replaced at the next change.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            commentsByRoot = archive.commentsByRoot.filter { !$0.value.isEmpty }
        }
    }

    /// Ordered by path, then line; comments on the same line keep the order they were added in.
    public func comments(in root: URL) -> [ReviewComment] {
        commentsByRoot[Self.key(root)] ?? []
    }

    public func add(_ comment: ReviewComment, in root: URL) {
        let key = Self.key(root)
        if sentByRoot[key] != nil { sentByRoot[key] = nil }
        var comments = commentsByRoot[key] ?? []
        comments.removeAll { $0.id == comment.id }
        // Inserting after every equal key, rather than sorting, is what keeps ties in insertion order.
        let index = comments.firstIndex { Self.sortsBefore(comment, $0) } ?? comments.endIndex
        comments.insert(comment, at: index)
        commentsByRoot[key] = comments
    }

    public func update(_ id: ReviewComment.ID, body: String, in root: URL) {
        let key = Self.key(root)
        guard let index = commentsByRoot[key]?.firstIndex(where: { $0.id == id }) else { return }
        commentsByRoot[key]?[index].body = body
    }

    public func remove(_ id: ReviewComment.ID, in root: URL) {
        let key = Self.key(root)
        guard var comments = commentsByRoot[key] else { return }
        comments.removeAll { $0.id == id }
        commentsByRoot[key] = comments.isEmpty ? nil : comments
    }

    public func removeAll(in root: URL) {
        commentsByRoot[Self.key(root)] = nil
    }

    /// The comments last sent from the worktree, which no longer count as pending.
    public func sentComments(in root: URL) -> [ReviewComment] {
        sentByRoot[Self.key(root)] ?? []
    }

    /// Called once the comments have gone to an agent: they leave the pending list, replacing the
    /// batch sent before them.
    public func markSent(in root: URL) {
        let key = Self.key(root)
        guard let comments = commentsByRoot[key] else { return }
        sentByRoot[key] = comments
        commentsByRoot[key] = nil
    }

    /// Puts the last sent batch back among the pending comments, for when it never reached the agent.
    public func restoreSent(in root: URL) {
        let key = Self.key(root)
        guard let sent = sentByRoot.removeValue(forKey: key) else { return }
        for comment in sent { add(comment, in: root) }
    }

    /// For a worktree whose folder moved: its pending comments and its last sent batch follow it.
    /// Left under the old folder, `retain(only:)` would drop them as belonging to a worktree that
    /// is gone, and the sent batch could no longer be restored.
    public func move(from oldRoot: URL, to newRoot: URL) {
        let old = Self.key(oldRoot)
        let new = Self.key(newRoot)
        guard old != new else { return }
        if let sent = sentByRoot.removeValue(forKey: old) {
            sentByRoot[new] = sent
        }
        guard let moved = commentsByRoot[old] else { return }
        var comments = commentsByRoot[new] ?? []
        for comment in moved {
            comments.removeAll { $0.id == comment.id }
            let index = comments.firstIndex { Self.sortsBefore(comment, $0) } ?? comments.endIndex
            comments.insert(comment, at: index)
        }
        // One write, so the store is saved once and never holds the comments under both folders.
        var all = commentsByRoot
        all[old] = nil
        all[new] = comments
        commentsByRoot = all
    }

    /// Drops the comments of every worktree not in `roots`: once a worktree is gone nothing shows
    /// them, and no session is left to send them to.
    public func retain(only roots: [URL]) {
        let keys = Set(roots.map(Self.key))
        if !sentByRoot.keys.allSatisfy(keys.contains) { sentByRoot = sentByRoot.filter { keys.contains($0.key) } }
        guard !commentsByRoot.isEmpty else { return }
        // Checked first so the common case, nothing to drop, does not write an observed property.
        guard !commentsByRoot.keys.allSatisfy(keys.contains) else { return }
        commentsByRoot = commentsByRoot.filter { keys.contains($0.key) }
    }

    /// Writes pending changes right away, for when the app is about to quit.
    public func saveNow() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        // Losing comments to a full disk is not worth an alert in the middle of a review; the next
        // change tries again.
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(Archive(commentsByRoot: commentsByRoot)).write(to: fileURL, options: .atomic)
        } catch {}
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private static func sortsBefore(_ lhs: ReviewComment, _ rhs: ReviewComment) -> Bool {
        lhs.path != rhs.path ? lhs.path < rhs.path : lhs.line < rhs.line
    }

    /// A path rather than a URL: `URL` equality keeps the trailing slash of a directory, so the same
    /// worktree reached as `/a/b` and `/a/b/` would otherwise hold two separate sets of comments.
    static func key(_ root: URL) -> String {
        var path = root.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// A session the comments can be sent to; the app supplies these.
public struct ReviewTarget: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var symbolName: String

    public init(id: UUID, title: String, symbolName: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
    }
}

public enum ReviewPrompt {
    /// Longer lines are cut: the agent has the file, the quote only has to make the line recognisable.
    static let maximumQuoteLength = 160

    /// The text pasted into the agent.
    ///
    /// Each comment names `path:line` itself, so the agent can act on one without reading the others,
    /// and comments on the same file are kept together in the order they first appear.
    public static func text(for comments: [ReviewComment]) -> String {
        guard !comments.isEmpty else { return "" }
        var paths: [String] = []
        var byPath: [String: [ReviewComment]] = [:]
        for comment in comments {
            if byPath[comment.path] == nil { paths.append(comment.path) }
            byPath[comment.path, default: []].append(comment)
        }

        var lines = [comments.count == 1
            ? "Please address this review comment on your changes:"
            : "Please address these review comments on your changes:"]
        for path in paths {
            for comment in byPath[path] ?? [] {
                lines.append("")
                lines.append(location(of: comment))
                lines.append(quote(comment.lineText))
                lines += bodyLines(comment.body)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func location(of comment: ReviewComment) -> String {
        var notes: [String] = []
        // An old-side number is meaningless against the current file unless the agent knows it is one.
        if comment.side == .old { notes.append("removed line") }
        // Staged line numbers count in the index version, which can differ from the working tree.
        if comment.staged { notes.append("staged version") }
        let location = "\(comment.path):\(comment.line)"
        return notes.isEmpty ? location : "\(location) (\(notes.joined(separator: ", ")))"
    }

    /// Inline code, fenced with more backticks than the line contains so a backtick in it cannot end
    /// the span early.
    static func quote(_ lineText: String) -> String {
        var code = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return "(blank line)" }
        if code.count > maximumQuoteLength {
            code = String(code.prefix(maximumQuoteLength)).trimmingCharacters(in: .whitespaces) + "..."
        }
        var longestRun = 0
        var run = 0
        for character in code {
            run = character == "`" ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: longestRun + 1)
        let padding = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
        return fence + padding + code + padding + fence
    }

    private static func bodyLines(_ body: String) -> [String] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // By isNewline, since a pasted "\r\n" is one Character and never equals "\n".
        return trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            var line = String(line)
            while let last = line.last, last.isWhitespace { line.removeLast() }
            return line
        }
    }
}
