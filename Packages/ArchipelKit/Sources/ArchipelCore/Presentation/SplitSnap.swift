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

/// Converts between the shares of the width the workspace keeps per pane and where a split view
/// has its dividers.
public enum SplitShares {
    /// The leading edge of every divider, measured from where the first pane starts. `total` is
    /// the room for all panes and their dividers. Empty when there is nothing to place.
    public static func dividerPositions(shares: [Double], total: Double, thickness: Double) -> [Double] {
        let sum = shares.reduce(0, +)
        let available = total - thickness * Double(shares.count - 1)
        guard shares.count > 1, available > 0, shares.allSatisfy({ $0 > 0 }) else { return [] }
        var end = 0.0
        return shares.dropLast().enumerated().map { index, share in
            end += available * share / sum
            return end + thickness * Double(index)
        }
    }

    /// Nil while a pane has no width, as in the middle of a layout pass. Remembering that would
    /// bring the pane back collapsed.
    public static func shares(widths: [Double]) -> [Double]? {
        let sum = widths.reduce(0, +)
        guard !widths.isEmpty, widths.allSatisfy({ $0 > 0 }) else { return nil }
        return widths.map { $0 / sum }
    }
}
