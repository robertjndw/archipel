import Foundation

/// Pulls a split divider to the middle when it gets close, so two panes can be made equal by feel.
public enum SplitSnap {
    public static let threshold = 8.0

    /// The divider's leading edge to use, and whether it was pulled to the center.
    /// `total` is the width of the split view and `thickness` that of the divider.
    public static func resolve(
        position: Double,
        total: Double,
        thickness: Double,
        threshold: Double = SplitSnap.threshold
    ) -> (position: Double, snapped: Bool) {
        let center = (total - thickness) / 2
        guard total > thickness, abs(position - center) <= threshold else { return (position, false) }
        return (center, true)
    }
}

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
            old == .working || old.needsUser ? .finished : nil
        case .needsAttention:
            // A request that only changes its reason is still the same request.
            old.needsUser ? nil : .needsInput
        case .exited(let code):
            code == 0 ? nil : .failed
        case .notStarted, .starting, .working:
            nil
        }
    }
}
