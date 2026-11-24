import ACPKit
import ArchipelCore
import Foundation
import Synchronization

/// Events read from a client and not yet folded into the session.
///
/// The reader appends from a background task and asks for a drain only when none is pending, so
/// a burst of streamed chunks ends up in one drain and one view update instead of one per token.
final class EventInbox: Sendable {
    private struct State {
        var events: [ACPEvent] = []
        var drainScheduled = false
    }

    private let state = Mutex(State())

    /// Returns true when the caller has to schedule a drain.
    func append(_ event: ACPEvent) -> Bool {
        state.withLock { state in
            state.events.append(event)
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
    }

    func takeAll() -> [ACPEvent] {
        state.withLock { state in
            state.drainScheduled = false
            defer { state.events = [] }
            return state.events
        }
    }
}

extension ChatSession {
    /// Reads `client.events` for the client's whole life. Order is kept: one reader, one FIFO,
    /// and each drain takes everything queued so far.
    func startReading(_ client: ACPClient, into inbox: EventInbox) {
        let events = client.events
        Task.detached { [weak self] in
            for await event in events {
                guard inbox.append(event) else { continue }
                Task { @MainActor [weak self] in
                    self?.drain(inbox)
                }
            }
        }
    }

    func drain(_ inbox: EventInbox) {
        let events = inbox.takeAll()
        guard inbox === self.inbox, !events.isEmpty else { return }

        // Folded on a uniquely held copy and stored once, so observers see one change per drain
        // and appending to a long message never copies the transcript.
        var working = transcript
        transcript = ChatTranscript()
        var effects: [Event] = []
        var reportedActivity = false
        for event in events {
            fold(event, into: &working, effects: &effects, reportedActivity: &reportedActivity)
        }
        transcript = working
        refreshPermissionToolCalls()
        reportTitleAndUsage(into: &effects)
        emit(effects)
    }

    private func fold(_ event: ACPEvent, into transcript: inout ChatTranscript, effects: inout [Event], reportedActivity: inout Bool) {
        switch event {
        case let .sessionUpdate(notification):
            guard isOwnSession(notification.sessionId) else { return }
            transcript.apply(notification.update)
            guard isTurnRunning, !transcript.isReplaying else { return }
            confirmSessionID(into: &effects)
            if !reportedActivity, activityReportIsDue() {
                reportedActivity = true
                effects.append(.agent(.activity))
            }

        case let .permissionRequest(id, request):
            guard isOwnSession(request.sessionId) else { return }
            if transcript.toolCall(id: request.toolCall.toolCallId) == nil {
                // The row the card belongs to has to exist; Codex asks before announcing the call.
                transcript.apply(.toolCallUpdate(request.toolCall))
            }
            let permission = ChatPermissionRequest(
                id: id,
                options: request.options,
                toolCall: Self.displayToolCall(request.toolCall, known: transcript.toolCall(id: request.toolCall.toolCallId)),
                requestedToolCall: request.toolCall
            )
            permissionRequests.append(permission)
            guard !transcript.isReplaying else { return }
            effects.append(Self.attentionEvent(for: permission))

        case let .permissionRequestWithdrawn(id):
            permissionRequests.removeAll { $0.id == id }

        case let .promptFinished(sessionId, result):
            guard isOwnSession(sessionId), isTurnRunning else { return }
            finishTurn(result, transcript: &transcript, effects: &effects)

        case let .replayStarted(sessionId):
            guard isOwnSession(sessionId) else { return }
            transcript.beginReplay()

        case let .sessionLoaded(sessionId, _):
            // Success or not, the replay is over; `openSession` decides what the result means.
            guard isOwnSession(sessionId) else { return }
            if transcript.isReplaying { transcript.endReplay() }
            replayEnded()

        case .authStatus:
            break

        case let .closed(reason):
            connectionClosed(reason, transcript: &transcript, effects: &effects)
        }
    }

    /// What the owner hears while `request` waits for an answer.
    static func attentionEvent(for request: ChatPermissionRequest) -> Event {
        let title = request.toolCall.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .agent(.attentionRequested(.permission, message: title.isEmpty ? nil : title))
    }

    /// Updates for another session than ours could only come from a confused agent. Before a
    /// session id is known, everything is ours: `session/new` may stream updates before it answers.
    private func isOwnSession(_ sessionId: String) -> Bool {
        agentSessionID == nil || agentSessionID == sessionId
    }

    private func activityReportIsDue() -> Bool {
        let now = ContinuousClock.now
        if let last = lastActivityReport, now - last < Self.activityInterval { return false }
        lastActivityReport = now
        return true
    }

    func confirmSessionID(into effects: inout [Event]) {
        guard !isAgentSessionIDConfirmed, let agentSessionID else { return }
        isAgentSessionIDConfirmed = true
        effects.append(.agentSessionIDConfirmed(agentSessionID))
    }

    private func finishTurn(_ result: Result<PromptResponse, ACPError>, transcript: inout ChatTranscript, effects: inout [Event]) {
        switch result {
        case let .success(response):
            confirmSessionID(into: &effects)
            transcript.endTurn(response.stopReason)
            // Only a turn that ran to its end is followed by what was typed ahead. The owner then
            // hears nothing yet: to whoever waits for a notification, the agent is done when the
            // last queued prompt is.
            let continues = response.stopReason == .endTurn && !queuedPrompts.isEmpty
            endTurnState(continuesWithQueue: continues)
            if !continues { effects.append(.agent(.turnFinished(message: transcript.lastAgentText))) }

        case let .failure(error) where error.isAuthenticationRequired:
            // Claude lets a signed-out user open a session and only refuses the first prompt.
            // The bubble stays; after sign-in the same prompt goes out again without a second one.
            transcript.endTurn(nil)
            let prompt = runningPrompt
            endTurnState()
            if let prompt { pendingRetry = .prompt(prompt) }
            let failure = signInFailure()
            phase = .failed(failure)
            effects.append(.failed(failure))

        case .failure(.connectionClosed):
            // `.closed` follows right behind and ends the turn with the reason.
            break

        case let .failure(error):
            transcript.endTurn(nil)
            endTurnState()
            turnError = Self.readableTurnError(error)
            effects.append(.agent(.turnFinished(message: nil)))
        }
    }

    func endTurnState(continuesWithQueue: Bool = false) {
        if continuesWithQueue, !queuedPrompts.isEmpty {
            // After the events at hand: they are still being applied to the transcript the next
            // prompt's bubble goes into.
            Task { [weak self] in
                guard let self, !self.sendNextQueuedPrompt() else { return }
                // The queue was emptied in the meantime, so this was the last turn after all.
                self.emit(.agent(.turnFinished(message: self.transcript.lastAgentText)))
            }
        } else {
            returnQueueToDraft()
        }
        isTurnRunning = false
        isCancelling = false
        isCancelIgnored = false
        cancelGraceTask?.cancel()
        cancelGraceTask = nil
        runningPrompt = nil
        // A request still open after its turn can never be answered usefully.
        permissionRequests.removeAll()
    }

    private func connectionClosed(_ reason: ACPCloseReason, transcript: inout ChatTranscript, effects: inout [Event]) {
        closeReason = reason
        if transcript.isReplaying { transcript.endReplay() }
        replayEnded()
        if isTurnRunning { transcript.endTurn(nil) }
        endTurnState()
        // While starting, the step that was waiting on the agent fails and reports it, and a
        // failure already on screen says more than "it quit".
        switch phase {
        case .starting, .failed, .ended:
            return
        case .ready:
            break
        }
        let ending = makeEnding(reason)
        phase = .ended(ending)
        // The process is gone; holding on to it would keep its object until the app quits.
        client = nil
        connection = nil
        effects.append(.agent(.processExited(code: Self.exitCode(reportedFor: reason))))
    }

    func makeEnding(_ reason: ACPCloseReason) -> ChatEnding {
        let stderr = stderrTail()
        switch reason {
        case .exited(code: 0), .closedByClient:
            return ChatEnding(exitCode: reason == .closedByClient ? nil : 0, isClean: true, message: "\(agentName) has quit.")
        case let .exited(code):
            return ChatEnding(
                exitCode: code, isClean: false,
                message: "\(agentName) quit unexpectedly (exit code \(code)).", details: stderr
            )
        case .signaled:
            return ChatEnding(exitCode: nil, isClean: false, message: "\(agentName) was stopped unexpectedly.", details: stderr)
        case .endOfStream, .protocolError, .transportError:
            return ChatEnding(exitCode: nil, isClean: false, message: "The connection to \(agentName) was lost.", details: stderr)
        }
    }

    /// The status for `.processExited`, which needs one even when the process was not seen to exit.
    /// Signals follow the shell's 128 + n; an unexplained end counts as a failure.
    static func exitCode(reportedFor reason: ACPCloseReason) -> Int32 {
        switch reason {
        case let .exited(code): code
        case let .signaled(signal): 128 + signal
        case .closedByClient: 0
        case .endOfStream, .protocolError, .transportError: 1
        }
    }

    /// The last lines of the agent's stderr, or nil when it printed nothing.
    func stderrTail(maxLines: Int = 12, maxCharacters: Int = 2000) -> String? {
        guard let text = connection?.stderrText() else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).suffix(maxLines)
        let tail = String(lines.joined(separator: "\n").suffix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    // MARK: Permission display

    /// The transcript's call with the request's own fields on top.
    static func displayToolCall(_ requested: ToolCallUpdate, known: ToolCall?) -> ToolCall {
        guard var call = known else { return requested.asToolCall }
        call.merge(requested)
        return call
    }

    /// Keeps cards in step with updates to their tool calls that arrived after the request.
    func refreshPermissionToolCalls() {
        guard !permissionRequests.isEmpty else { return }
        for index in permissionRequests.indices {
            let request = permissionRequests[index]
            let refreshed = Self.displayToolCall(request.requestedToolCall, known: transcript.toolCall(id: request.requestedToolCall.toolCallId))
            if refreshed != request.toolCall { permissionRequests[index].toolCall = refreshed }
        }
    }

    // MARK: Title and usage

    /// Reports title and usage when they changed, but not before the chat is ready: replayed
    /// values go out once, after `.sessionStarted`.
    func reportTitleAndUsage(into effects: inout [Event]) {
        guard !transcript.isReplaying, !isReplayPending else { return }
        if case .starting = phase { return }
        if let title = transcript.title, title != reportedTitle {
            reportedTitle = title
            effects.append(.titleChanged(title))
        }
        if let usage = transcript.usage, usage.used != reportedUsage?.used || usage.size != reportedUsage?.size {
            reportedUsage = usage
            effects.append(.usageChanged(used: usage.used, size: usage.size))
        }
    }

    // MARK: Replay

    /// Returns once `.sessionLoaded` or `.closed` was folded. A connection that closed before the
    /// load was even sent yields neither again, so a known close returns at once.
    func waitForReplayEnd() async {
        guard isReplayPending, closeReason == nil, inbox != nil else {
            isReplayPending = false
            return
        }
        await withCheckedContinuation { replayWaiters.append($0) }
    }

    func replayEnded() {
        isReplayPending = false
        let waiters = replayWaiters
        replayWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: Messages

    static func readableTurnError(_ error: ACPError) -> String {
        if case let .rpc(rpc) = error, !rpc.message.isEmpty {
            return "The response couldn't be completed: \(rpc.message)"
        }
        return "The response couldn't be completed."
    }
}
