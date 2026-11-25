import Foundation

/// The glow a worktree plays when one of its sessions changes state, colored by what happened. The
/// app holds it back while it is in the background, where nobody would see it.
/// Cases are declared from least to most urgent, so several changes while the app was away can
/// play as one glow: `max()` of them is the one that most needs you.
public enum StatusPulse: Comparable, Sendable {
    case finished
    case failed
    case needsInput

    /// Nil for changes that are not worth drawing the eye to.
    public static func kind(from old: SessionStatus, to new: SessionStatus) -> StatusPulse? {
        switch new {
        case .finished:
            // A session that merely became ready after launching is not a result.
            old.isMidTurn ? .finished : nil
        case .needsAttention:
            // A request that only changes its reason is still the same request.
            old.needsUser ? nil : .needsInput
        case .exited(let code):
            code == 0 ? nil : .failed
        case .notStarted, .starting, .working:
            nil
        }
    }

    /// Requests and failures glow right away. A finished turn waits until nothing in the worktree
    /// is running, otherwise it calls you back while subagents or another tab are still going.
    ///
    /// A background subagent finishing doesn't glow by itself. Claude hands its result back to the
    /// main agent, which usually keeps going, and that turn glows when it ends.
    ///
    /// `siblings` are the worktree's other sessions, which this change did not touch.
    public static func kind(
        from before: SessionActivity,
        to after: SessionActivity,
        siblings: some Sequence<SessionActivity>
    ) -> StatusPulse? {
        guard let kind = kind(from: before.status, to: after.status) else { return nil }
        guard kind == .finished else { return kind }
        return after.isBusy || siblings.contains(where: \.isBusy) ? nil : .finished
    }
}
