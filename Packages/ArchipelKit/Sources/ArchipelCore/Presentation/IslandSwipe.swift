import Foundation

/// The math of the two-finger swipe between islands, free of AppKit so it can be tested. The view
/// layer feeds it scroll deltas and reads back where the content should be and where the gesture ends.
public struct IslandSwipe: Equatable, Sendable {
    public enum Axis: Equatable, Sendable { case undecided, horizontal, vertical }

    /// Past this share of the width a release commits even without speed.
    public static let commitFraction = 0.3
    /// Points per second of a flick that commits on its own.
    public static let flickVelocity = 450.0
    /// A flick shorter than this is a twitch, not an intent.
    public static let minimumFlickDistance = 12.0
    /// How far the content may be pulled past the first or last island, as a share of the width.
    public static let rubberBandLimit = 0.3

    public let islandCount: Int
    public let selectedIndex: Int
    public let width: Double
    public private(set) var axis: Axis = .undecided
    /// Where the fingers are, in points, positive to the right.
    public private(set) var translation = 0.0
    private var vertical = 0.0
    private var samples: [Sample] = []

    private struct Sample: Equatable, Sendable {
        var delta: Double
        var time: Double
    }

    public init(islandCount: Int, selectedIndex: Int, width: Double) {
        self.islandCount = islandCount
        self.selectedIndex = selectedIndex
        self.width = max(width, 1)
    }

    /// Feeds one scroll event. Deltas are the finger direction, so moving right is positive.
    @discardableResult
    public mutating func update(dx: Double, dy: Double, time: Double) -> Axis {
        switch axis {
        case .vertical:
            return axis
        case .horizontal:
            translation += dx
            record(dx, at: time)
        case .undecided:
            translation += dx
            vertical += dy
            record(dx, at: time)
            // Decided early and for good, so a gesture that starts as a vertical scroll never starts
            // dragging the content sideways halfway through.
            if abs(translation) + abs(vertical) >= 6 {
                axis = abs(translation) > abs(vertical) * 1.5 ? .horizontal : .vertical
                if axis == .vertical { translation = 0 }
            }
        }
        return axis
    }

    private mutating func record(_ delta: Double, at time: Double) {
        samples.append(Sample(delta: delta, time: time))
        samples.removeAll { time - $0.time > 0.1 }
    }

    /// Recent finger speed in points per second.
    public var velocity: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let span = max(last.time - first.time, 0.03)
        return samples.reduce(0) { $0 + $1.delta } / span
    }

    /// Moving right reveals the previous island, which is the one to the left.
    private var direction: Int { translation > 0 ? -1 : 1 }

    private func exists(_ index: Int) -> Bool { index >= 0 && index < islandCount }

    /// Where to draw the content: it follows the fingers one to one, and resists once there is no
    /// island on that side.
    public var offset: Double {
        guard axis == .horizontal else { return 0 }
        if exists(selectedIndex + direction) {
            return min(max(translation, -width), width)
        }
        let limit = width * Self.rubberBandLimit
        return (translation < 0 ? -1 : 1) * Self.rubberBand(abs(translation), limit: limit)
    }

    /// The index the release lands on, which is the current one when the swipe falls short or has
    /// nowhere to go.
    public func settledIndex(endingVelocity: Double? = nil) -> Int {
        guard axis == .horizontal else { return selectedIndex }
        let target = selectedIndex + direction
        guard exists(target) else { return selectedIndex }
        let speed = endingVelocity ?? velocity
        let flicked = abs(translation) >= Self.minimumFlickDistance
            && abs(speed) >= Self.flickVelocity
            && (speed > 0) == (translation > 0)
        let dragged = abs(translation) >= width * Self.commitFraction
        return flicked || dragged ? target : selectedIndex
    }

    /// Diminishing returns toward `limit`, like a scroll view pulled past its edge.
    public static func rubberBand(_ distance: Double, limit: Double) -> Double {
        guard distance > 0, limit > 0 else { return 0 }
        let coefficient = 0.55
        return (1 - 1 / (distance * coefficient / limit + 1)) * limit
    }
}
