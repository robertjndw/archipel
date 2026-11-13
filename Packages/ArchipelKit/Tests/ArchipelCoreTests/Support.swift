import Foundation
@testable import ArchipelCore

func makeSession(_ title: String = "s") -> Session {
    Session(title: title, agent: .claude, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}

func makeWorktree(_ name: String = "w", isMain: Bool = false, branch: String? = nil, sessions: [Session] = []) -> Worktree {
    Worktree(path: URL(fileURLWithPath: "/tmp/\(name)"), branch: branch, isMain: isMain, sessions: sessions)
}

/// A project whose main worktree holds the given sessions.
func makeProject(_ name: String = "p", sessions: [Session] = []) -> Project {
    Project(
        name: name,
        folderURL: URL(fileURLWithPath: "/tmp/\(name)"),
        worktrees: [makeWorktree(name, isMain: true, sessions: sessions)]
    )
}
