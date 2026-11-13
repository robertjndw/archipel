import Foundation

/// The first on-disk format, where sessions hung directly off a project and
/// carried their own working directory. Kept only so existing workspaces
/// survive the move to Island > Project > Worktree > Session.
struct LegacyWorkspaceV1: Decodable {
    struct LegacyWorktree: Decodable {
        var path: URL
        var branch: String
    }

    struct LegacySession: Decodable {
        var id: UUID
        var title: String
        var agent: AgentKind
        var agentSessionID: String?
        var workingDirectory: URL
        var worktree: LegacyWorktree?
        var createdAt: Date
    }

    struct LegacyProject: Decodable {
        var id: UUID
        var name: String
        var folderURL: URL
        var sessions: [LegacySession]
    }

    struct LegacyIsland: Decodable {
        var id: UUID
        var name: String
        var symbol: String
        var tint: Tint
        var projects: [LegacyProject]
    }

    var islands: [LegacyIsland]
    var selectedIslandID: UUID?
    var selectedSessionIDByIsland: [UUID: UUID]

    func migrated() -> Workspace {
        var workspace = Workspace(
            islands: islands.map { island in
                Island(
                    id: island.id,
                    name: island.name,
                    symbol: island.symbol,
                    tint: island.tint,
                    projects: island.projects.map(Self.migrate)
                )
            },
            selectedIslandID: selectedIslandID
        )
        // selectSession also records the worktree, which the old format had no notion of.
        let current = workspace.selectedIslandID
        for (_, sessionID) in selectedSessionIDByIsland { workspace.selectSession(sessionID) }
        if let current { workspace.selectIsland(current) }
        return workspace
    }

    private static func migrate(_ project: LegacyProject) -> Project {
        var main = Worktree(path: project.folderURL, isMain: true)
        var others: [Worktree] = []
        for old in project.sessions {
            let session = Session(
                id: old.id,
                title: old.title,
                agent: old.agent,
                agentSessionID: old.agentSessionID,
                createdAt: old.createdAt
            )
            guard let oldWorktree = old.worktree else {
                main.sessions.append(session)
                continue
            }
            if let index = others.firstIndex(where: { $0.path == oldWorktree.path }) {
                others[index].sessions.append(session)
            } else {
                others.append(Worktree(path: oldWorktree.path, branch: oldWorktree.branch, sessions: [session]))
            }
        }
        return Project(id: project.id, name: project.name, folderURL: project.folderURL, worktrees: [main] + others)
    }
}
