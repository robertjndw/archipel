import AgentKit
import ArchipelCore
import EditorUI
import Foundation

/// Review comments headed for a session that could not take input yet.
struct PendingReview {
    /// The worktree whose comments are sent. Read again at delivery, so comments added meanwhile go too.
    var root: URL
    var requestedAt: ContinuousClock.Instant
}

extension AppModel {
    /// Agents other than Claude are marked started as soon as their terminal exists, while their TUI
    /// is still drawing itself; text pasted then can land in the shell wrapper or be dropped.
    static let reviewSettleTimeForUnhookedAgents = Duration.seconds(2.5)
    /// Claude reports readiness through its SessionStart hook; the pause only covers the gap between
    /// the hook firing and the prompt accepting a paste.
    static let reviewSettleTimeForClaude = Duration.milliseconds(500)
    /// Long enough for a slow first start (Claude can take several seconds), short enough that the user
    /// still connects the message to what they did.
    static let reviewDeliveryTimeout = Duration.seconds(30)

    /// Agent sessions only: a plain shell would run the prompt's lines as commands.
    func reviewTargets(in worktree: Worktree) -> [ReviewTarget] {
        worktree.sessions.filter { $0.agent != .shell }.map { session in
            ReviewTarget(
                id: session.id,
                title: session.displayTitle,
                symbolName: AgentDefinition.builtIn(id: session.agent.rawValue)?.symbolName ?? "terminal"
            )
        }
    }

    /// Pastes every comment of the worktree into the session without pressing Return: the agent may be
    /// mid-turn or showing a permission prompt, and the user should see the prompt before it is sent.
    func sendReviewComments(in worktreeID: Worktree.ID, to sessionID: Session.ID) {
        guard let worktree = workspace.worktree(id: worktreeID), let session = workspace.session(id: sessionID),
              !reviewComments.comments(in: worktree.path).isEmpty
        else { return }
        if case .exited = activity(for: sessionID).status {
            problem = "\(session.displayTitle) is not running, so the review comments were not sent. Restart it and try again; your comments are kept."
            return
        }
        let pending = PendingReview(root: worktree.path, requestedAt: .now)
        pendingReviews[sessionID] = pending
        // Selecting starts a session that has not been shown yet.
        select(session: sessionID)
        deliverPendingReview(to: sessionID)
        if pendingReviews[sessionID] != nil { scheduleReviewTimeout(for: sessionID, requestedAt: pending.requestedAt) }
    }

    /// Called whenever a session's status changes, which is when a waiting delivery may become possible.
    func sessionStatusChanged(_ id: Session.ID, from old: SessionStatus, to new: SessionStatus) {
        if pendingReviews[id] != nil {
            // The settle time counts from when the agent reported ready, not from when its terminal was
            // created: Claude's hook fires seconds after launch, by which time a pause measured from the
            // launch would already be used up.
            if old == .starting { terminalStartTimes[id] = .now }
            deliverPendingReview(to: id)
        }
        let endedWork = switch new {
        case .finished: old == .working || old.isAttention
        case .exited: true
        default: false
        }
        if endedWork, let worktree = workspace.worktree(containing: id) {
            refreshGitStatus(of: [worktree.id], lookingUpPullRequests: true)
        }
    }

    private func deliverPendingReview(to id: Session.ID) {
        guard let pending = pendingReviews[id] else { return }
        guard let session = workspace.session(id: id) else {
            pendingReviews[id] = nil
            return
        }
        let status = activity(for: id).status
        if case .exited = status {
            pendingReviews[id] = nil
            problem = "\(session.displayTitle) stopped before the review comments could be sent. Your comments are kept."
            return
        }
        guard let terminal = terminals[id], status != .starting, status != .notStarted,
              let startedAt = terminalStartTimes[id]
        else { return }

        let settle = session.agent == .claude ? Self.reviewSettleTimeForClaude : Self.reviewSettleTimeForUnhookedAgents
        let wait = settle - startedAt.duration(to: .now)
        if wait > .zero {
            Task { [weak self] in
                try? await Task.sleep(for: wait)
                // The terminal may have been restarted meanwhile; only the same process counts.
                guard let self, self.terminals[id] === terminal else { return }
                self.deliverPendingReview(to: id)
            }
            return
        }

        pendingReviews[id] = nil
        let comments = reviewComments.comments(in: pending.root)
        guard !comments.isEmpty else { return }
        terminal.sendText(ReviewPrompt.text(for: comments))
        reviewComments.removeAll(in: pending.root)
        // Selecting swapped tabs; the terminal view only accepts focus once SwiftUI has put it in the window.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, self.terminals[id] === terminal else { return }
            terminal.focus()
        }
    }

    /// A session that never becomes ready (hooks unavailable, an agent stuck at a login screen) must not
    /// swallow the comments silently, nor receive them unexpectedly minutes later.
    private func scheduleReviewTimeout(for id: Session.ID, requestedAt: ContinuousClock.Instant) {
        Task { [weak self] in
            try? await Task.sleep(until: requestedAt.advanced(by: Self.reviewDeliveryTimeout), clock: .continuous)
            guard let self, self.pendingReviews[id]?.requestedAt == requestedAt else { return }
            self.pendingReviews[id] = nil
            let title = self.workspace.session(id: id)?.displayTitle ?? "The session"
            self.problem = "\(title) did not get ready for input, so the review comments were not sent. Your comments are kept."
        }
    }
}

private extension SessionStatus {
    var isAttention: Bool {
        if case .needsAttention = self { return true }
        return false
    }
}
