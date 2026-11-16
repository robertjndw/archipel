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

/// True when every worktree has a pane, each session has exactly one tab, and no tab points at a missing session.
func invariantsHold(_ ws: Workspace) -> Bool {
    ws.allWorktrees.allSatisfy { worktree in
        let shown = worktree.panes.flatMap(\.tabs).compactMap { tab -> Session.ID? in
            if case .session(let id) = tab.content { return id }
            return nil
        }
        let panesOK = !worktree.panes.isEmpty
            && (worktree.panes.count == 1 || worktree.panes.allSatisfy { !$0.tabs.isEmpty })
            && worktree.focusedPane != nil
        return panesOK && shown.sorted { $0.uuidString < $1.uuidString } == worktree.sessions.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }
}

struct UnexpectedNil: Error {}

extension Optional {
    /// For values returned by mutating calls, which `#require` cannot wrap.
    func unwrapped() throws -> Wrapped {
        guard let self else { throw UnexpectedNil() }
        return self
    }
}
