import Foundation

/// Why a session wants the user.
public enum AttentionReason: String, Codable, Sendable {
    /// The agent is blocked on a tool or command approval.
    case permission
    /// The agent asked something and is waiting for an answer.
    case question
}

public enum SessionStatus: Equatable, Sendable {
    /// Known to the app but no process is running (fresh, or not yet resumed after relaunch).
    case notStarted
    case starting
    case working
    case needsAttention(AttentionReason)
    /// The agent completed its turn and is waiting at its prompt.
    case finished
    case exited(code: Int32)

    public var needsUser: Bool {
        if case .needsAttention = self { return true }
        return false
    }
}

/// Everything the app learns about a running session, from either channel:
/// agent hooks (precise) or the terminal itself (generic, works for any CLI).
public enum AgentEvent: Equatable, Sendable {
    /// The app spawned the process.
    case launched
    /// The agent reported that it is up and at its prompt.
    case sessionStarted
    case promptSubmitted
    /// Tool use or other proof that the agent is busy.
    case activity
    case attentionRequested(AttentionReason, message: String?)
    /// `backgroundTasks` is how many shells, monitors and the like the agent left running, or nil
    /// when the agent does not say. Subagents are not among them: they report themselves.
    case turnFinished(message: String?, backgroundTasks: Int? = nil)
    /// OSC 9 / OSC 777 desktop notification from the terminal.
    case terminalNotification(title: String, body: String)
    case bell
    case processExited(code: Int32)
    /// An agent the user started by hand in a shell tab exited, and the shell's prompt is back. The
    /// terminal itself keeps running, so this is not an exit.
    case agentLeft
    /// Claude started a subagent. Ids are Claude's `agent_id`.
    case subagentStarted(id: String)
    /// A hook fired from inside a subagent, such as one of its tool calls.
    case subagentActivity(id: String)
    case subagentFinished(id: String)
}
