import Foundation

/// Where a palette entry takes the user.
public enum WorkspaceDestination: Hashable, Sendable {
    case island(Island.ID)
    case worktree(Worktree.ID)
    case session(Session.ID)
}

public struct WorkspaceDestinationEntry: Equatable, Sendable {
    public var destination: WorkspaceDestination
    /// What the user sees and what is matched first.
    public var title: String
    /// Context such as "Island / Project / branch", matched after the title.
    public var subtitle: String

    public init(destination: WorkspaceDestination, title: String, subtitle: String) {
        self.destination = destination
        self.title = title
        self.subtitle = subtitle
    }
}

public extension Workspace {
    /// Every island, worktree and session in sidebar order: an island, then its worktrees, each followed by its sessions.
    func destinationEntries() -> [WorkspaceDestinationEntry] {
        var entries: [WorkspaceDestinationEntry] = []
        for island in islands {
            let count = island.projects.count
            entries.append(WorkspaceDestinationEntry(
                destination: .island(island.id),
                title: island.name,
                subtitle: count == 1 ? "1 project" : "\(count) projects"
            ))
            for project in island.projects {
                for worktree in project.worktrees {
                    let context = "\(island.name) / \(project.name)"
                    entries.append(WorkspaceDestinationEntry(
                        destination: .worktree(worktree.id),
                        title: worktree.displayName,
                        subtitle: context
                    ))
                    for session in worktree.sessions {
                        entries.append(WorkspaceDestinationEntry(
                            destination: .session(session.id),
                            title: session.displayTitle,
                            subtitle: "\(context) / \(worktree.displayName)"
                        ))
                    }
                }
            }
        }
        return entries
    }
}
