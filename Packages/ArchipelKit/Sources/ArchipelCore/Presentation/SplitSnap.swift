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
