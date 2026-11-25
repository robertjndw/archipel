import Foundation

extension SessionActivity {
    /// What a session has to say wherever sessions are summed up, ranked or filtered: counts,
    /// badges, the "Needs Me" list, the jump to the next session, the menu bar. Each session is
    /// exactly one of these or none, so no two of those places can disagree about it.
    /// Declared most pressing first.
    public enum Attention: Comparable, Sendable {
        /// Blocked on an answer.
        case needsUser
        /// Starting up, in the middle of a turn, or waiting on background subagents.
        case working
        /// Something the user has not looked at: a finished turn, an exit, a bell. Only once the
        /// session is no longer working, the way a result's glow waits for the worktree to settle.
        case unread
    }

    public var attention: Attention? {
        if needsUser { return .needsUser }
        if showsProgress { return .working }
        if unread { return .unread }
        return nil
    }

    /// What the jump to the next session lands on and the "Needs Me" filter lists. Only the jump
    /// ranks the two.
    public var needsMe: Bool {
        attention == .needsUser || attention == .unread
    }
}

/// How many sessions are in each state of `SessionActivity.Attention`. A session is counted once.
public struct AttentionSummary: Equatable, Sendable {
    public var needsAttention: Int
    public var unread: Int
    /// Not attention as such, but what tells the user that something is still going on in a place
    /// they are not looking at.
    public var working: Int

    public init(needsAttention: Int = 0, unread: Int = 0, working: Int = 0) {
        self.needsAttention = needsAttention
        self.unread = unread
        self.working = working
    }

    public static let zero = AttentionSummary()

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            needsAttention: lhs.needsAttention + rhs.needsAttention,
            unread: lhs.unread + rhs.unread,
            working: lhs.working + rhs.working
        )
    }

    /// The single strongest signal, for places with room for one indicator. Ranked like
    /// `SessionActivity.Attention`, so a group shows what its most pressing session shows.
    public var dominant: Signal? {
        if needsAttention > 0 { return .needsAttention(needsAttention) }
        if working > 0 { return .working }
        if unread > 0 { return .unread }
        return nil
    }

    public enum Signal: Equatable, Sendable {
        case needsAttention(Int)
        case unread
        case working
    }

    /// For VoiceOver; empty when there is nothing to report.
    public var accessibilityDescription: String {
        var parts: [String] = []
        if needsAttention > 0 { parts.append("\(needsAttention) waiting for you") }
        if unread > 0 { parts.append("\(unread) unread") }
        if working > 0 { parts.append(working == 1 ? "1 agent working" : "\(working) agents working") }
        return parts.joined(separator: ", ")
    }
}

public func attentionSummary(of sessions: [Session], activities: [Session.ID: SessionActivity]) -> AttentionSummary {
    sessions.reduce(.zero) { total, session in
        switch activities[session.id]?.attention {
        case .needsUser: total + AttentionSummary(needsAttention: 1)
        case .working: total + AttentionSummary(working: 1)
        case .unread: total + AttentionSummary(unread: 1)
        case nil: total
        }
    }
}

public func attentionSummary(of worktree: Worktree, activities: [Session.ID: SessionActivity]) -> AttentionSummary {
    attentionSummary(of: worktree.sessions, activities: activities)
}

public func attentionSummary(of project: Project, activities: [Session.ID: SessionActivity]) -> AttentionSummary {
    project.worktrees.reduce(.zero) { $0 + attentionSummary(of: $1, activities: activities) }
}

public func attentionSummary(of island: Island, activities: [Session.ID: SessionActivity]) -> AttentionSummary {
    island.projects.reduce(.zero) { $0 + attentionSummary(of: $1, activities: activities) }
}

public func attentionSummary(of workspace: Workspace, activities: [Session.ID: SessionActivity]) -> AttentionSummary {
    workspace.islands.reduce(.zero) { $0 + attentionSummary(of: $1, activities: activities) }
}

/// The session that stands for a group of them where there is room for one, such as a worktree's
/// row: the most pressing one, the first of those in the order given.
public func mostPressingSession(of sessions: [Session], activities: [Session.ID: SessionActivity]) -> Session.ID? {
    var best: (id: Session.ID, attention: SessionActivity.Attention)?
    for session in sessions {
        guard let attention = activities[session.id]?.attention else { continue }
        if best.map({ attention < $0.attention }) ?? true { best = (session.id, attention) }
    }
    return best?.id
}

/// Walks sessions in sidebar order starting after `current`, wrapping around (and ending on
/// `current` itself). Sessions waiting on the user win over unread ones.
public func nextSessionNeedingAttention(
    after current: Session.ID?,
    in workspace: Workspace,
    activities: [Session.ID: SessionActivity]
) -> Session.ID? {
    let ids = workspace.allSessions.map(\.id)
    let start = current.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    let ordered = ids[start...] + ids[..<start]

    if let hit = ordered.first(where: { activities[$0]?.attention == .needsUser }) { return hit }
    return ordered.first { activities[$0]?.attention == .unread }
}

/// The worktrees holding a session that the jump to the next session could land on, in any island.
public func worktreesNeedingAttention(in workspace: Workspace, activities: [Session.ID: SessionActivity]) -> Set<Worktree.ID> {
    Set(workspace.allWorktrees.filter { worktree in
        worktree.sessions.contains { activities[$0.id]?.needsMe == true }
    }.map(\.id))
}
