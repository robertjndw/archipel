import Foundation

/// Live, non-persisted state of one session, derived purely from the event stream.
public struct SessionActivity: Equatable, Sendable {
    /// Requests only exist while the session waits for the user, so a status written from
    /// outside `apply` cannot leave one behind.
    public var status: SessionStatus {
        didSet { if !status.needsUser { pendingRequests = [] } }
    }
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
    /// What the agent is waiting for an answer to, oldest first. Usually one, but subagents ask
    /// independently of each other and of the main agent. A status of `needsAttention` set from
    /// outside comes without one and is treated as a request nobody claimed.
    public private(set) var pendingRequests: [PendingRequest] = []
    /// The user sent something into the terminal and no turn has been reported to end since. For
    /// an agent whose hooks say nothing about its turns this is the one sign that a turn may be
    /// running: such an agent only ever reports the end of one.
    public private(set) var awaitsTurnEnd = false

    public init(status: SessionStatus = .notStarted, unread: Bool = false, lastMessage: String? = nil, completedTurn: Bool = false) {
        self.status = status
        self.unread = unread
        self.lastMessage = Self.displayed(lastMessage)
        self.completedTurn = completedTurn
    }

    public var needsUser: Bool { status.needsUser }

    /// One thing the agent asked the user, as far as its hooks described it.
    public struct PendingRequest: Equatable, Sendable {
        public enum Requester: Equatable, Sendable {
            case main
            case subagent(String)
            /// Nothing said who asked, as with Claude's notification standing in for a request
            /// hook that never came. Whoever acts next is taken to have been answered.
            case unknown
        }

        public var reason: AttentionReason
        /// What is being asked, as shown to the user.
        public var summary: String?
        public var requester: Requester
        /// `summary` leaves out some of what is being asked.
        public var isPartial: Bool

        public init(reason: AttentionReason, summary: String?, requester: Requester, isPartial: Bool = false) {
            self.reason = reason
            self.summary = summary
            self.requester = requester
            self.isPartial = isPartial
        }
    }

    /// The request the status and `lastMessage` describe: the newest one.
    public var pendingRequest: PendingRequest? {
        needsUser ? pendingRequests.last : nil
    }

    /// Whether an answer can be typed into the terminal on the strength of the summary alone.
    /// With several requests waiting there is no telling which one the agent's prompt is showing,
    /// and a partial summary does not say what would be approved.
    public var canAnswerUnseen: Bool {
        needsUser && pendingRequests.count <= 1 && pendingRequest?.isPartial != true
    }

    /// Whether the session asks the user something `before` did not: a first request, or another
    /// one taking its place while the status stays the same. Either is news, and what was said
    /// about the earlier one (a banner, its buttons) no longer describes what is waiting.
    public func asksSomethingNew(since before: SessionActivity) -> Bool {
        needsUser && (status != before.status || pendingRequest != before.pendingRequest)
    }

    /// Longer than a banner or a row ever shows, short enough that a runaway message costs nothing.
    static let messageLimit = 500

    /// Every message kept here ends up in a notification or the sidebar.
    private static func displayed(_ message: String?) -> String? {
        guard let message else { return nil }
        let line = DisplayLine(message, limit: messageLimit, blanks: .dropped).text
        return line.isEmpty ? nil : line
    }

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

    /// Drives the spinner. Unlike `isBusy` it includes `.starting`. A pending request wins over
    /// running subagents, so that session shows and counts as waiting, not working.
    public var showsProgress: Bool {
        status == .starting || (isBusy && !needsUser)
    }

    public mutating func markViewed() {
        unread = false
    }

    /// The user pressed Return in the session's terminal.
    public mutating func inputSubmitted() {
        // Nothing reads what is typed into a process that has exited.
        if case .exited = status { return }
        awaitsTurnEnd = true
    }

    /// A result or a request stays unread until the user actually engages with the session, by
    /// clicking into it or sending a prompt. Merely being on screen is not enough: people leave the
    /// window open and walk away. `isBeingViewed` only quiets the terminal bell, which fires while
    /// someone is typing.
    public mutating func apply(_ event: AgentEvent, isBeingViewed: Bool, at now: Date = Date()) {
        // A dead process stays dead until the app relaunches it.
        if case .exited = status, event != .launched { return }
        // Only a turn in flight can be interrupted. Anything else is a late report about a turn
        // that has ended some other way since, and must leave its background subagents alone.
        if event == .turnInterrupted, !status.isMidTurn { return }
        let previous = status
        let previousRequest = pendingRequest
        let wasBusy = isBusy
        subagents.apply(event, at: now)

        switch event {
        case .launched:
            status = .starting
            unread = false
            lastMessage = nil
            completedTurn = false
            backgroundTasks = 0
            awaitsTurnEnd = false
        case .sessionStarted:
            // Hooks can arrive late, so this must not pull a busy session back to idle.
            // It is also not a result worth badging, hence the early return.
            if status == .starting || status == .notStarted { status = .finished }
            return
        case .subagentStarted:
            // Only the roster changes.
            break
        case .subagentFinished(let id):
            // The last subagent of an ended turn leaving is when that turn's result is finally
            // ready, which the check below picks up. A subagent that leaves also takes its
            // request with it.
            settleRequests { $0 == .subagent(id) }
        case .subagentActivity(let id):
            // A background subagent keeps calling tools after the main turn has ended, and that
            // must not reopen the turn. The one status it does change is its own request: a
            // subagent's permission prompt is reported as the session's, and that subagent's next
            // tool call means the user answered it. A tool call from any other subagent says
            // nothing about a request someone else is known to have made. One nobody claimed is
            // taken as answered by whoever acts next.
            settleRequests { $0 == .subagent(id) || $0 == .unknown }
        case .promptSubmitted:
            completedTurn = false
            status = .working
            // Typing the next prompt is the clearest sign the last result was seen.
            unread = false
        case .activity:
            completedTurn = false
            // The main agent can go on calling tools while one of its subagents waits for an
            // answer, and the session is still blocked on that.
            if status.needsUser {
                settleRequests { $0 == .main || $0 == .unknown }
            } else {
                status = .working
            }
        case .attentionRequested(let reason, let message, let subagent, let isPartial):
            let message = Self.displayed(message)
            let requester = subagent.map(PendingRequest.Requester.subagent) ?? .main
            // An agent shows one prompt at a time, so a second request from the same one replaces
            // its first. A stand-in is for a request that has now arrived itself.
            pendingRequests.removeAll { $0.requester == requester || $0.requester == .unknown }
            pendingRequests.append(PendingRequest(reason: reason, summary: message, requester: requester, isPartial: isPartial))
            status = .needsAttention(reason)
            lastMessage = message ?? lastMessage
        case .attentionReminder(let reason, let message):
            // The request itself said what is being asked and by whom, and this must not replace
            // either. It stands in for the request only when the agent sent none.
            if !status.needsUser {
                let message = Self.displayed(message)
                pendingRequests = [PendingRequest(reason: reason, summary: message, requester: .unknown)]
                status = .needsAttention(reason)
                lastMessage = message ?? lastMessage
            }
        case .turnFinished(let message, let backgroundTasks):
            status = .finished
            completedTurn = true
            awaitsTurnEnd = false
            lastMessage = Self.displayed(message) ?? lastMessage
            if let backgroundTasks { self.backgroundTasks = backgroundTasks }
        case .backgroundTasksChanged(let count):
            // Says nothing about the turn, so neither the status nor the unread mark moves.
            backgroundTasks = count
            return
        case .turnInterrupted:
            status = .finished
            completedTurn = false
            // The user did this at the terminal, so there is no result to point them to.
            return
        case .terminalNotification(_, let body):
            lastMessage = Self.displayed(body) ?? lastMessage
            // Fallback for agents without hooks. Only a running turn is promoted, so a precise
            // .permission or a settled .finished is never overwritten by a generic notification.
            if status == .working || status == .starting { status = .needsAttention(.question) }
        case .bell:
            if !isBeingViewed { unread = true }
        case .processExited(let code):
            status = .exited(code: code)
            backgroundTasks = 0
            awaitsTurnEnd = false
        case .agentLeft:
            // Idle, but with no completed turn to show. What the agent did is in the scrollback,
            // not in a result the sidebar could link to.
            status = .finished
            completedTurn = false
            backgroundTasks = 0
            awaitsTurnEnd = false
        }

        markUnreadIfSettled(from: previous, wasBusy: wasBusy)
        // A request that takes another's place is as much news as the first one was.
        if needsUser, pendingRequest != previousRequest { unread = true }
    }

    /// Takes the requests of the matching askers as answered.
    private mutating func settleRequests(from answered: (PendingRequest.Requester) -> Bool) {
        guard status.needsUser else { return }
        if pendingRequests.isEmpty {
            guard answered(.unknown) else { return }
        } else {
            let waiting = pendingRequests.filter { !answered($0.requester) }
            guard waiting.count != pendingRequests.count else { return }
            pendingRequests = waiting
        }
        // Back to where the session was before the request: a subagent can ask after the main
        // turn has ended.
        showNextRequest(orSettleTo: completedTurn ? .finished : .working)
    }

    private mutating func showNextRequest(orSettleTo settled: SessionStatus) {
        guard let next = pendingRequests.last else {
            status = settled
            return
        }
        status = .needsAttention(next.reason)
        lastMessage = next.summary ?? lastMessage
    }

    /// For an answer the app gave itself, such as from a notification's button. No hook reports
    /// it back, or not reliably: Claude sends nothing when a request is denied. `settled` is where
    /// that leaves the session, unless another request is still waiting behind the answered one;
    /// that one then becomes the session's unread request.
    public mutating func resolveRequest(to settled: SessionStatus) {
        if needsUser, !pendingRequests.isEmpty { pendingRequests.removeLast() }
        showNextRequest(orSettleTo: settled)
        unread = needsUser
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
