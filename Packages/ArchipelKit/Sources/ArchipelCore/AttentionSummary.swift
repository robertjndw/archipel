import Foundation

public struct AttentionSummary: Equatable, Sendable {
    public var needsAttention: Int
    public var unread: Int

    public init(needsAttention: Int = 0, unread: Int = 0) {
        self.needsAttention = needsAttention
        self.unread = unread
    }

    public static let zero = AttentionSummary()

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(needsAttention: lhs.needsAttention + rhs.needsAttention, unread: lhs.unread + rhs.unread)
    }
}

public func attentionSummary(of sessions: [Session], activities: [Session.ID: SessionActivity]) -> AttentionSummary {
    sessions.reduce(.zero) { total, session in
        guard let activity = activities[session.id] else { return total }
        return total + AttentionSummary(
            needsAttention: activity.needsUser ? 1 : 0,
            unread: activity.unread ? 1 : 0
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
    return ordered.first { id in
        guard let activity = activities[id] else { return false }
        return activity.status == .finished && activity.unread
    }
}
