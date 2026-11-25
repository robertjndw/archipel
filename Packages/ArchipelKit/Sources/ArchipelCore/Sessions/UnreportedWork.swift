/// Work in a session's terminal that its `SessionActivity` status does not account for, and that
/// stopping the session would kill: what closing a tab, restarting or quitting asks about on top
/// of a turn the hooks reported.
public enum UnreportedWork: Equatable, Sendable {
    /// What holds the session's terminal.
    public enum Occupant: Equatable, Sendable {
        /// A project script the app started in place of an agent.
        case script
        /// A shell the user types commands into.
        case shell
        case agent(reportsLifecycleThroughHooks: Bool)
    }

    case script
    /// A turn of an agent that would not have said it began.
    case agentTurn
    /// A command the user started from a shell, by the name to show for it.
    case command(String)

    /// - Parameters:
    ///   - processIsAlive: The terminal still has a process that stopping would end.
    ///   - shellForegroundCommand: What runs in front of a shell, nil at its prompt. Only asked
    ///     for a shell, since it reads the process table.
    public static func find(
        in occupant: Occupant,
        activity: SessionActivity,
        processIsAlive: Bool,
        shellForegroundCommand: () -> String?
    ) -> UnreportedWork? {
        guard processIsAlive else { return nil }
        switch occupant {
        case .script:
            return .script
        case .shell:
            return shellForegroundCommand().map { .command($0) }
        case .agent(let reportsLifecycleThroughHooks):
            // Hooks report every turn, so the status is the whole story.
            if reportsLifecycleThroughHooks { return nil }
            // Without them the agent holds the terminal the same way working or idle, and the
            // most it reports is the end of a turn. Being alive is therefore no reason to ask:
            // an agent that was given nothing, or that has said it is done, has nothing to lose.
            // One the user sent something to and that has not reported back since may be in the
            // middle of it.
            return activity.awaitsTurnEnd ? .agentTurn : nil
        }
    }
}
