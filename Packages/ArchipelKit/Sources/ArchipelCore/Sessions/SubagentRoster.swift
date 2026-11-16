import Foundation

/// The subagents a session has running, from Claude's SubagentStart and SubagentStop hooks.
///
/// A stop can go missing, for example when the user interrupts the turn, and a count that never
/// goes down is worse than none. So entries also expire: right away at the end of the main turn
/// if they have been quiet for a minute (foreground subagents always end before their parent
/// does), and after ten quiet minutes in any case. A background subagent dropped too early comes
/// back with its next tool call.
public struct SubagentRoster: Equatable, Sendable {
    private var lastSeen: [String: Date] = [:]

    static let quietAtTurnEnd: TimeInterval = 60
    static let quietLimit: TimeInterval = 10 * 60

    public init() {}

    public var count: Int { lastSeen.count }

    mutating func apply(_ event: AgentEvent, at now: Date) {
        lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) < Self.quietLimit }
        switch event {
        case .subagentStarted(let id), .subagentActivity(let id):
            lastSeen[id] = now
        case .subagentFinished(let id):
            lastSeen[id] = nil
        case .turnFinished:
            lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) < Self.quietAtTurnEnd }
        case .launched, .sessionStarted, .processExited:
            lastSeen = [:]
        case .promptSubmitted, .activity, .attentionRequested, .terminalNotification, .bell:
            break
        }
    }
}
