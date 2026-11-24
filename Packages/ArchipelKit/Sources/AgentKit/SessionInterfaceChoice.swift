import ArchipelCore

extension Session {
    /// What the session runs as right now. A chat needs an agent that speaks ACP, and has no use
    /// for a script tab or for a preset, whose arguments are for the CLI and mean nothing to the
    /// ACP agent. Anything else is a terminal, whatever was asked for.
    public var effectiveInterface: SessionInterface {
        interface == .acp && agent.adapter.acp != nil && script == nil && arguments == nil ? .acp : .terminal
    }
}

extension SessionInterface {
    /// The interface a new session of an agent starts with, given what the user prefers for that
    /// agent. Using a preset forces the terminal, for the same reason as in `Session.effectiveInterface`.
    public static func forNewSession(
        of adapter: any AgentAdapter,
        preferred: SessionInterface,
        usesPreset: Bool
    ) -> SessionInterface {
        preferred == .acp && adapter.acp != nil && !usesPreset ? .acp : .terminal
    }
}
