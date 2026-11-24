/// How a session is shown and driven.
public enum SessionInterface: String, Codable, Sendable, CaseIterable {
    /// The agent's own CLI in a terminal tab.
    case terminal
    /// A native chat the app drives over the Agent Client Protocol.
    case acp
}
