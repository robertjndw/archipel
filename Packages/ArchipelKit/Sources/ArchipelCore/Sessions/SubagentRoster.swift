import Foundation

/// The subagents a session has running, from Claude's SubagentStart and SubagentStop hooks.
///
/// Anything still listed when the main turn ends is background work, so the turn end leaves it
/// alone. Stops do get lost (an interrupted turn, say), so entries expire after ten quiet minutes.
/// That outlasts any single tool call, since Claude's Bash tool times out at ten minutes. The app
/// runs a timer for `nextExpiry` because no further hook event may come along to prune them.
public struct SubagentRoster: Equatable, Sendable {
    private var lastSeen: [String: Date] = [:]

    static let quietLimit: TimeInterval = 10 * 60

    public init() {}

    public var count: Int { lastSeen.count }

    /// When the quietest entry runs out, or nil when nothing is running.
    public var nextExpiry: Date? {
        lastSeen.values.min().map { $0 + Self.quietLimit }
    }

    mutating func expire(at now: Date) {
        lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) < Self.quietLimit }
    }

    mutating func apply(_ event: AgentEvent, at now: Date) {
        expire(at: now)
        switch event {
        case .subagentStarted(let id), .subagentActivity(let id):
            lastSeen[id] = now
        case .subagentFinished(let id):
            lastSeen[id] = nil
        case .launched, .sessionStarted, .processExited, .agentLeft:
            lastSeen = [:]
        case .promptSubmitted, .activity, .attentionRequested, .turnFinished, .terminalNotification, .bell:
            break
        }
    }
}
