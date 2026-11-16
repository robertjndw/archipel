import Foundation

/// The pure parts of peeking at a session from the sidebar without opening it.
public enum SessionPeek {
    /// One stop when stepping through the sidebar with the arrow keys while a
    /// peek is open. A worktree with several sessions shows a row per session,
    /// so it gets a stop per session too; otherwise the worktree is one stop.
    public struct Target: Hashable, Sendable {
        public var worktreeID: Worktree.ID
        /// nil when the worktree has no sessions.
        public var sessionID: Session.ID?

        public init(worktreeID: Worktree.ID, sessionID: Session.ID?) {
            self.worktreeID = worktreeID
            self.sessionID = sessionID
        }
    }

    /// The session that best stands for a worktree: one that needs the user,
    /// then a busy one, then the one its content area shows, then whatever
    /// has a live terminal.
    public static func mostRelevantSession(
        in worktree: Worktree,
        activities: [Session.ID: SessionActivity],
        focusedSessionID: Session.ID?,
        isLive: (Session.ID) -> Bool
    ) -> Session.ID? {
        let sessions = worktree.sessions
        if let id = sessions.first(where: { activities[$0.id]?.needsUser == true })?.id { return id }
        if let id = sessions.first(where: {
            let status = activities[$0.id]?.status
            return status == .working || status == .starting
        })?.id { return id }
        if let focusedSessionID, sessions.contains(where: { $0.id == focusedSessionID }) { return focusedSessionID }
        return sessions.first(where: { isLive($0.id) })?.id ?? sessions.first?.id
    }

    /// The stops in sidebar order: expanded projects only, since collapsed
    /// ones have no rows to step through.
    public static func targets(
        in island: Island,
        relevantSession: (Worktree) -> Session.ID?
    ) -> [Target] {
        island.projects.filter(\.isExpanded).flatMap(\.worktrees).flatMap { worktree -> [Target] in
            if worktree.sessions.count > 1 {
                return worktree.sessions.map { Target(worktreeID: worktree.id, sessionID: $0.id) }
            }
            return [Target(worktreeID: worktree.id, sessionID: relevantSession(worktree))]
        }
    }

    /// The stop `offset` rows away, clamped to the ends like a list selection.
    /// A target that is no longer listed starts over from the top.
    public static func step(from current: Target, by offset: Int, in targets: [Target]) -> Target? {
        guard !targets.isEmpty else { return nil }
        guard let index = targets.firstIndex(of: current)
                ?? targets.firstIndex(where: { $0.worktreeID == current.worktreeID })
        else { return targets.first }
        return targets[min(max(index + offset, 0), targets.count - 1)]
    }

    /// The last `count` lines that hold something. Trailing blank lines are
    /// what an idle terminal is mostly made of below its prompt, and showing
    /// them would push the actual output out of the peek.
    public static func tail(of text: String, lines count: Int) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.reversed().drop(while: \.isWhitespace).reversed())
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return Array(lines.suffix(count))
    }
}
