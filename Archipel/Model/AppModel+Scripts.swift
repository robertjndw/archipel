import AgentKit
import ArchipelCore
import Foundation

/// A project script running as a session's process.
struct ScriptRun: Equatable {
    enum Kind {
        case setup, run

        var title: String {
            switch self {
            case .setup: "Setup"
            case .run: "Run"
            }
        }
    }

    var kind: Kind
    var command: String
}

extension AppModel {
    func project(ofWorktree id: Worktree.ID?) -> Project? {
        id.flatMap { workspace.project(containingWorktree: $0) }
    }

    func openProjectSettings(_ id: Project.ID) {
        projectSettingsID = id
    }

    func saveScripts(_ scripts: ProjectScripts, of id: Project.ID) {
        mutate { $0.updateProject(id: id) { $0.scripts = scripts } }
    }

    /// The Run command: restarts this run's Run session if the worktree has one, otherwise starts a
    /// new one. Without a run script there is nothing to start, so the settings open instead.
    func runProject(in worktreeID: Worktree.ID) {
        guard let project = project(ofWorktree: worktreeID) else { return }
        guard project.scripts.runCommand != nil else {
            openProjectSettings(project.id)
            return
        }
        startScript(.run, in: worktreeID)
    }

    /// Reuses the worktree's live session of that kind so repeated runs do not pile up tabs (and a
    /// second dev server does not fight the first over its port). The script is read again each
    /// time, so edits in the settings apply on the next run.
    func startScript(_ kind: ScriptRun.Kind, in worktreeID: Worktree.ID) {
        guard let worktree = workspace.worktree(id: worktreeID), let project = project(ofWorktree: worktreeID) else { return }
        let command = switch kind {
        case .setup: project.scripts.setupCommand
        case .run: project.scripts.runCommand
        }
        guard let command else { return }
        let run = ScriptRun(kind: kind, command: command)

        if let existing = worktree.sessions.first(where: { scriptSessions[$0.id]?.kind == kind }) {
            scriptSessions[existing.id] = run
            select(session: existing.id)
            restartSession(existing.id)
            return
        }

        // A custom title, because the terminal title of a script is whatever the script prints there.
        let session = Session(title: kind.title, hasCustomTitle: true, agent: .shell)
        // Registered before the session exists in the workspace, since selecting it starts it.
        scriptSessions[session.id] = run
        changingSelection {
            _ = $0.addSession(session, to: worktreeID)
            $0.selectSession(session.id)
        }
    }
}
