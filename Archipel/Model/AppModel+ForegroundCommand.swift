import AgentKit
import AppKit
import ArchipelCore
import TerminalKit

/// Work in a terminal that no hook reports: a dev server, ssh or a build in a shell tab, a project
/// script, or a turn of an agent that never said it began. `SessionActivity`'s status knows nothing
/// of these, so closing the tab, restarting or quitting has to ask the terminal itself.
extension AppModel {
    /// What stopping the session would kill that its activity does not account for, as the subject
    /// of "... is running": "npm run dev", "its script", "Codex". Nil when nothing would be lost.
    ///
    /// Ghostty's own check comes first, so `confirm-close-surface = false` in the user's config
    /// turns this off, and an exited process never asks. The rest is `UnreportedWork`.
    func foregroundCommand(of id: Session.ID) -> String? {
        guard let session = workspace.session(id: id), let terminal = terminals[id] else { return nil }
        let agent = effectiveAgent(for: session)
        let occupant: UnreportedWork.Occupant = if scriptSessions[id] != nil {
            .script
        } else if isPlainShell(session) {
            .shell
        } else {
            .agent(reportsLifecycleThroughHooks: agent.reportsLifecycleThroughHooks)
        }
        let work = UnreportedWork.find(
            in: occupant,
            activity: activities[id] ?? SessionActivity(),
            processIsAlive: terminal.needsCloseConfirmation,
            shellForegroundCommand: { Self.shellForegroundCommand(in: terminal) }
        )
        return switch work {
        case .script?: "its script"
        case .agentTurn?: agent.adapter.displayName
        case .command(let label)?: label
        case nil: nil
        }
    }

    /// What runs in front of a shell, nil while it sits at its prompt.
    ///
    /// Ghostty's check is not enough for a shell: sessions are started through a wrapper, which
    /// keeps Ghostty from injecting its shell integration, and without marked prompts it takes
    /// every shell for busy. The foreground process group tells an idle one apart: at its prompt
    /// the shell itself holds the terminal.
    private static func shellForegroundCommand(in terminal: TerminalSession) -> String? {
        guard let group = terminal.foregroundProcessID else { return nil }
        // A job whose first process has exited while the rest of the pipeline runs has no leader.
        guard let leader = ProcessSampler.process(group), leader.processGroupID == group else { return "a command" }
        let (name, arguments) = ProcessSampler.name(of: group)
        if AgentProcessMatcher.isInteractiveShell(name: name, arguments: arguments) { return nil }
        // Until the shell has taken the terminal for itself, what is in front is the launcher that
        // starts it. A tab closed right after it was opened has nothing to lose.
        guard wasStartedFromAShell(leader) else { return nil }
        let label = ProcessLabel.label(name: name, arguments: arguments)
        return label.isEmpty ? "a command" : label
    }

    /// Whether one of the process's ancestors in its terminal is a shell at its prompt, which is
    /// what tells a command the user typed from the processes that lead up to their shell.
    private static func wasStartedFromAShell(_ process: ProcessEntry) -> Bool {
        var parent = process.parentPID
        // Bounded, in case the table changes under the walk and a pid leads back to itself.
        for _ in 0..<16 {
            guard parent > 1, let entry = ProcessSampler.process(parent), entry.unixSessionID == process.unixSessionID else { return false }
            let (name, arguments) = ProcessSampler.name(of: parent)
            if AgentProcessMatcher.isInteractiveShell(name: name, arguments: arguments) { return true }
            parent = entry.parentPID
        }
        return false
    }

    /// How many sessions quitting would cut short: the ones closing a tab asks about.
    var sessionsWithWorkInFlight: Int {
        workspace.allSessionIDs.filter { activities[$0]?.hasWorkInFlight == true || foregroundCommand(of: $0) != nil }.count
    }
}
