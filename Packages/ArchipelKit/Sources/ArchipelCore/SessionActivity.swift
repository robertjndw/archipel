import Foundation

/// Live, non-persisted state of one session, derived purely from the event stream.
public struct SessionActivity: Equatable, Sendable {
    public var status: SessionStatus
    /// Something happened that the user has not looked at yet.
    public var unread: Bool
    public var lastMessage: String?
    /// The last turn ran to its end. `.finished` alone also covers an agent that has only just
    /// started and sits at its first prompt, which has nothing to show as done.
    public var completedTurn: Bool

    public init(status: SessionStatus = .notStarted, unread: Bool = false, lastMessage: String? = nil, completedTurn: Bool = false) {
        self.status = status
        self.unread = unread
        self.lastMessage = lastMessage
        self.completedTurn = completedTurn
    }

    public var needsUser: Bool { status.needsUser }

    public mutating func markViewed() {
        unread = false
    }

    /// A result or a request stays unread until the user actually engages with the session, by
    /// clicking into it or sending a prompt. Merely being on screen is not enough: people leave the
    /// window open and walk away. `isBeingViewed` only quiets the terminal bell, which fires while
    /// someone is typing.
    public mutating func apply(_ event: AgentEvent, isBeingViewed: Bool) {
        // A dead process stays dead until the app relaunches it.
        if case .exited = status, event != .launched { return }

        let previous = status
        switch event {
        case .launched:
            status = .starting
            unread = false
            lastMessage = nil
            completedTurn = false
        case .sessionStarted:
            // Hooks can arrive late, so this must not pull a busy session back to idle.
            // It is also not a result worth badging, hence the early return.
            if status == .starting || status == .notStarted { status = .finished }
            return
        case .promptSubmitted, .activity:
            status = .working
            completedTurn = false
            // Typing the next prompt is the clearest sign the last result was seen.
            if event == .promptSubmitted { unread = false }
        case .attentionRequested(let reason, let message):
            status = .needsAttention(reason)
            lastMessage = message ?? lastMessage
        case .turnFinished(let message):
            status = .finished
            completedTurn = true
            lastMessage = message ?? lastMessage
        case .terminalNotification(_, let body):
            lastMessage = body
            // Fallback for agents without hooks. Only a running turn is promoted, so a precise
            // .permission or a settled .finished is never overwritten by a generic notification.
            if status == .working || status == .starting { status = .needsAttention(.question) }
        case .bell:
            if !isBeingViewed { unread = true }
        case .processExited(let code):
            status = .exited(code: code)
        }

        if status != previous, Self.isNotable(status) { unread = true }
    }

    private static func isNotable(_ status: SessionStatus) -> Bool {
        switch status {
        case .needsAttention, .finished, .exited: true
        case .notStarted, .starting, .working: false
        }
    }
}
