import Foundation

public struct AttentionSummary: Equatable, Sendable {
    public var needsAttention: Int
    public var unread: Int
    /// Sessions starting up, in the middle of a turn, or waiting on background subagents. Not
    /// attention as such, but what tells the user that something is still going on in a place
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

    /// The single strongest signal, for places with room for one indicator.
    public var dominant: Signal? {
        if needsAttention > 0 { return .needsAttention(needsAttention) }
        if unread > 0 { return .unread }
        if working > 0 { return .working }
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
        guard let activity = activities[session.id] else { return total }
        return total + AttentionSummary(
            needsAttention: activity.needsUser ? 1 : 0,
            unread: activity.unread ? 1 : 0,
            working: activity.showsProgress ? 1 : 0
        )
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

extension SessionActivity {
    /// A turn that ran to its end and has not been looked at yet.
    public var hasUnreadResult: Bool { status == .finished && unread }

    /// What the jump to the next session lands on and the "Needs Me" filter lists: a request waiting
    /// for an answer, or a finished turn nobody has read. Only the jump ranks the two.
    public var needsMe: Bool { needsUser || hasUnreadResult }
}

/// Walks sessions in sidebar order starting after `current`, wrapping around (and ending on
/// `current` itself). Sessions waiting on the user win over unread finished ones.
public func nextSessionNeedingAttention(
    after current: Session.ID?,
    in workspace: Workspace,
    activities: [Session.ID: SessionActivity]
) -> Session.ID? {
    let ids = workspace.allSessions.map(\.id)
    let start = current.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    let ordered = ids[start...] + ids[..<start]

    if let hit = ordered.first(where: { activities[$0]?.needsUser == true }) { return hit }
    return ordered.first { activities[$0]?.hasUnreadResult == true }
}

/// The worktrees holding a session that the jump to the next session could land on, in any island.
public func worktreesNeedingAttention(in workspace: Workspace, activities: [Session.ID: SessionActivity]) -> Set<Worktree.ID> {
    Set(workspace.allWorktrees.filter { worktree in
        worktree.sessions.contains { activities[$0.id]?.needsMe == true }
    }.map(\.id))
}
