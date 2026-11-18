import AgentKit
import ArchipelCore
import Foundation

/// A project script running as a session's process.
struct ScriptRun: Equatable {
    typealias Kind = ScriptKind

    var kind: Kind
    var command: String
}

extension ScriptKind {
    var title: String {
        switch self {
        case .setup: "Setup"
        case .run: "Run"
        }
    }
}

extension AppModel {
    func project(ofWorktree id: Worktree.ID?) -> Project? {
        id.flatMap { workspace.project(containingWorktree: $0) }
    }

    func openProjectSettings(_ id: Project.ID, showingScripts: Bool = false) {
        guard readyForSheet() else { return }
        projectSettingsShowsScripts = showingScripts
        projectSettingsID = id
    }

    /// The Run command: restarts the worktree's Run session if it has one, otherwise starts a new
    /// one. Without a run script there is nothing to start, so the settings open instead.
    func runProject(in worktreeID: Worktree.ID) {
        guard let project = project(ofWorktree: worktreeID) else { return }
        guard project.scripts.runCommand != nil else {
            openProjectSettings(project.id, showingScripts: true)
            return
        }
        startScript(.run, in: worktreeID)
    }

    /// Reuses the worktree's session of that kind so repeated runs do not pile up tabs (and a
    /// second dev server does not fight the first over its port). That includes a tab restored
    /// after a relaunch, which is a plain shell until the script is run in it again. The script is
    /// read again each time, so edits in the settings apply on the next run.
    func startScript(_ kind: ScriptRun.Kind, in worktreeID: Worktree.ID) {
        guard let worktree = workspace.worktree(id: worktreeID), let project = project(ofWorktree: worktreeID) else { return }
        let command = switch kind {
        case .setup: project.scripts.setupCommand
        case .run: project.scripts.runCommand
        }
        guard let command else { return }
        let run = ScriptRun(kind: kind, command: command)

        if let existing = worktree.sessions.first(where: { $0.script == kind }) {
            scriptSessions[existing.id] = run
            select(session: existing.id)
            // No confirmation: running the script again is itself the request to stop the last run.
            restartSessionNow(existing.id)
            return
        }

        // A custom title, because the terminal title of a script is whatever the script prints there.
        let session = Session(title: kind.title, hasCustomTitle: true, agent: .shell, script: kind)
        // Registered before the session exists in the workspace, since selecting it starts it.
        scriptSessions[session.id] = run
        changingSelection {
            _ = $0.addSession(session, to: worktreeID)
            $0.selectSession(session.id)
        }
    }
}
