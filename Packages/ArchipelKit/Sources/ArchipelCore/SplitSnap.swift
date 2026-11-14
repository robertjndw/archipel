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

/// Decides when a finish glow plays: a turn that ends while nobody is looking.
public enum FinishPulse {
    public static func shouldPlay(from old: SessionStatus, to new: SessionStatus, isBeingViewed: Bool) -> Bool {
        guard new == .finished, !isBeingViewed else { return false }
        // A session that merely became ready after launching is not a result.
        return old == .working || old.needsUser
    }
}
