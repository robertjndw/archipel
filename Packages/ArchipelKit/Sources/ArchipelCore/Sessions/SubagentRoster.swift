import Foundation

/// The subagents a session has running, from Claude's SubagentStart and SubagentStop hooks.
///
/// Anything still listed when the main turn ends is background work, so the turn end leaves it
/// alone. Stops do get lost (an interrupted turn, say), so entries expire after ten quiet minutes.
/// The app runs a timer for `nextExpiry` because no further hook event may come along to prune
/// them.
///
/// A subagent can be quiet for longer than that and still be running, say while one tool call
/// hangs or it waits on a subagent of its own. Claude lists its running subagents when a turn
/// ends, and that list then replaces the roster.
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
        case .turnInterrupted:
            // An interrupt stops the subagents the turn was waiting on, and their stops are not
            // reported. One that runs in the background shows up again with its next tool call.
            lastSeen = [:]
        case .turnFinished(_, _, let running):
            // Brings back a subagent that expired while it was quiet, and drops one whose stop
            // got lost. The glow is decided on this event, so the roster has to be right here.
            if let running { lastSeen = Dictionary(running.map { ($0, now) }) { first, _ in first } }
        case .promptSubmitted, .activity, .attentionRequested, .attentionReminder, .backgroundTasksChanged, .terminalNotification, .bell:
            break
        }
    }
}
