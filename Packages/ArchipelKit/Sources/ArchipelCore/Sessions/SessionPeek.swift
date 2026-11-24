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

    /// Which of the peek's popovers are on screen, so keys are only taken while one is.
    ///
    /// One flag is not enough. Stepping to another worktree moves the popover to that row, and the
    /// new row's popover can appear before the old one has finished going away; the old one leaving
    /// would then clear the flag while a peek is plainly up, and the next arrow key would go to the
    /// list and change the real selection. AppKit can also take the old one down first, which leaves
    /// a moment with no popover at all, so a peek that was just moved counts as shown for a short
    /// grace period while its popover is on the way.
    public struct Presentation: Sendable {
        private var shown: Set<Worktree.ID> = []
        private var arriving: (worktree: Worktree.ID, since: Date)?

        /// Long enough for a popover to come up, short enough that a peek whose popover never
        /// does stops swallowing keys before anyone notices.
        public static let grace: TimeInterval = 0.5

        public init() {}

        public mutating func appeared(_ worktree: Worktree.ID) {
            shown.insert(worktree)
            if arriving?.worktree == worktree { arriving = nil }
        }

        public mutating func disappeared(_ worktree: Worktree.ID) {
            shown.remove(worktree)
        }

        /// The peek moved to `worktree`, whose popover has not appeared yet.
        public mutating func moving(to worktree: Worktree.ID, at now: Date = .now) {
            guard !shown.contains(worktree) else { return }
            arriving = (worktree, now)
        }

        public func isShowing(at now: Date = .now) -> Bool {
            if !shown.isEmpty { return true }
            guard let arriving else { return false }
            return now.timeIntervalSince(arriving.since) < Self.grace
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
        if let id = sessions.first(where: { activities[$0.id]?.showsProgress == true })?.id { return id }
        if let focusedSessionID, sessions.contains(where: { $0.id == focusedSessionID }) { return focusedSessionID }
        return sessions.first(where: { isLive($0.id) })?.id ?? sessions.first?.id
    }

    /// The stops in sidebar order: expanded projects only, since collapsed
    /// ones have no rows to step through.
    public static func targets(
        in island: Island,
        relevantSession: (Worktree) -> Session.ID?
    ) -> [Target] {
        targets(in: island.projects.filter(\.isExpanded).flatMap(\.worktrees), relevantSession: relevantSession)
    }

    /// The stops of whatever rows the sidebar lists, in its order. The "Needs Me" list has rows
    /// from every island and ignores collapsed projects, so the caller says which rows are shown.
    public static func targets(
        in worktrees: [Worktree],
        relevantSession: (Worktree) -> Session.ID?
    ) -> [Target] {
        worktrees.flatMap { worktree -> [Target] in
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
