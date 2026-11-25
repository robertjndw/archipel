import Foundation
import Observation

/// State of the chat's views that has to outlive them. A tab that is switched away from loses
/// its views, and a turn's elapsed time or an open find bar must not start over when it returns.
/// Chat tabs that share a pane even reuse the same views for another session, so state kept in
/// them would follow the pane instead of the chat.
///
/// The app opens and steps Find through the session's `canFind`, `showFind` and `stepFind`,
/// since the menu bar knows sessions, not views.
@MainActor @Observable
final class ChatViewState {
    /// Times the running turn for the status line.
    private(set) var turnClock = TurnClock()
    let find = ChatFindModel()

    @ObservationIgnored private var isFollowing = false

    /// Keeps the clock in step with `session` from now on. The chat view calls this when it
    /// appears, and only the first call does anything.
    ///
    /// The clock starts with whatever is running at that moment. A view is on screen before its
    /// composer can send anything, so that is normally every turn from its start; only a prompt the
    /// app sends to a chat that was never shown is timed from when it first is.
    func follow(_ session: ChatSession) {
        guard !isFollowing else { return }
        isFollowing = true
        track(session)
    }

    private func track(_ session: ChatSession) {
        let (turn, isWaiting) = withObservationTracking {
            (session.isTurnRunning ? session.turnCount : nil, !session.permissionRequests.isEmpty)
        } onChange: { [weak self, weak session] in
            // Observation reports a change before it is made. Reading it comes a step later.
            Task { @MainActor in
                guard let self, let session else { return }
                self.track(session)
            }
        }
        var clock = turnClock
        clock.update(turn: turn, isWaitingOnUser: isWaiting, now: .now)
        if clock != turnClock { turnClock = clock }
    }

    /// Sets the clock by hand, for previews of a turn that has been running for a while.
    func setTurnClock(_ clock: TurnClock) {
        isFollowing = true
        turnClock = clock
    }
}

extension ChatSession {
    /// Whether there is a conversation on screen to search.
    public var canFind: Bool {
        guard !transcript.items.isEmpty else { return false }
        switch phase {
        case .ready, .ended: return true
        case .starting, .failed: return false
        }
    }

    /// Opens Find in the conversation, or moves the cursor back into its field. False when
    /// there is nothing to search.
    @discardableResult
    public func showFind() -> Bool {
        guard canFind else { return false }
        viewState.find.present()
        return true
    }

    /// Steps to the next hit, or with `forward` false to the one before. Opens Find first when
    /// it is closed. False when there is nothing to search.
    @discardableResult
    public func stepFind(forward: Bool) -> Bool {
        guard canFind else { return false }
        viewState.find.step(forward: forward)
        return true
    }

    /// Closes Find and gives the keyboard back to the composer.
    func dismissFind() {
        guard viewState.find.isPresented else { return }
        viewState.find.dismiss()
        requestComposerFocus()
    }
}
