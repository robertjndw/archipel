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
    /// Subagents the agent has running, for the "+3" next to its status.
    public var subagents = SubagentRoster()
    /// Shells and other tasks the agent left running when its last turn ended, so only as fresh
    /// as that turn end. Left out of `isBusy` on purpose: a dev server never exits, and a session
    /// running one would never get to show a finished turn.
    public var backgroundTasks = 0

    public init(status: SessionStatus = .notStarted, unread: Bool = false, lastMessage: String? = nil, completedTurn: Bool = false) {
        self.status = status
        self.unread = unread
        self.lastMessage = lastMessage
        self.completedTurn = completedTurn
    }

    public var needsUser: Bool { status.needsUser }

    /// Stopping the session now would throw something away: a turn, a pending answer, or work
    /// the agent left running.
    public var hasWorkInFlight: Bool {
        isBusy || needsUser || backgroundTasks > 0
    }

    /// A finished turn with background subagents still running is not done yet. `.starting` is
    /// left out on purpose: a tab that is only booting shouldn't hold back another tab's result.
    public var isBusy: Bool {
        status == .working || subagents.count > 0
    }

    public mutating func markViewed() {
        unread = false
    }

    /// A result or a request stays unread until the user actually engages with the session, by
    /// clicking into it or sending a prompt. Merely being on screen is not enough: people leave the
    /// window open and walk away. `isBeingViewed` only quiets the terminal bell, which fires while
    /// someone is typing.
    public mutating func apply(_ event: AgentEvent, isBeingViewed: Bool, at now: Date = Date()) {
        // A dead process stays dead until the app relaunches it.
        if case .exited = status, event != .launched { return }
        let previous = status
        let wasBusy = isBusy
        subagents.apply(event, at: now)

        switch event {
        case .launched:
            status = .starting
            unread = false
            lastMessage = nil
            completedTurn = false
            backgroundTasks = 0
        case .sessionStarted:
            // Hooks can arrive late, so this must not pull a busy session back to idle.
            // It is also not a result worth badging, hence the early return.
            if status == .starting || status == .notStarted { status = .finished }
            return
        case .subagentStarted, .subagentFinished:
            // Only the roster changes, but the last subagent of an ended turn leaving is when that
            // turn's result is finally ready, which the check below picks up.
            break
        case .subagentActivity:
            // A background subagent keeps calling tools after the main turn has ended, and that
            // must not reopen the turn. The one status it does change is a request: a subagent's
            // permission prompt is reported as the session's, and its next tool call means the
            // user answered it.
            if status.needsUser { status = completedTurn ? .finished : .working }
        case .promptSubmitted, .activity:
            status = .working
            completedTurn = false
            // Typing the next prompt is the clearest sign the last result was seen.
            if event == .promptSubmitted { unread = false }
        case .attentionRequested(let reason, let message):
            status = .needsAttention(reason)
            lastMessage = message ?? lastMessage
        case .turnFinished(let message, let backgroundTasks):
            status = .finished
            completedTurn = true
            lastMessage = message ?? lastMessage
            if let backgroundTasks { self.backgroundTasks = backgroundTasks }
        case .terminalNotification(_, let body):
            lastMessage = body
            // Fallback for agents without hooks. Only a running turn is promoted, so a precise
            // .permission or a settled .finished is never overwritten by a generic notification.
            if status == .working || status == .starting { status = .needsAttention(.question) }
        case .bell:
            if !isBeingViewed { unread = true }
        case .processExited(let code):
            status = .exited(code: code)
            backgroundTasks = 0
        case .agentLeft:
            // Idle, but with no completed turn to show. What the agent did is in the scrollback,
            // not in a result the sidebar could link to.
            status = .finished
            completedTurn = false
            backgroundTasks = 0
        }

        markUnreadIfSettled(from: previous, wasBusy: wasBusy)
    }

    /// Drops subagents that went quiet for too long. Nothing else may arrive to do it, so the app
    /// calls this on a timer when `subagents.nextExpiry` passes.
    public mutating func expireSubagents(at now: Date = Date()) {
        let wasBusy = isBusy
        subagents.expire(at: now)
        markUnreadIfSettled(from: status, wasBusy: wasBusy)
    }

    private mutating func markUnreadIfSettled(from previous: SessionStatus, wasBusy: Bool) {
        let becameIdle = wasBusy && !isBusy
        let settled = status != previous || (status == .finished && becameIdle)
        if settled, Self.isNotable(status), !(status == .finished && isBusy) { unread = true }
    }

    private static func isNotable(_ status: SessionStatus) -> Bool {
        switch status {
        case .needsAttention, .finished, .exited: true
        case .notStarted, .starting, .working: false
        }
    }
}
