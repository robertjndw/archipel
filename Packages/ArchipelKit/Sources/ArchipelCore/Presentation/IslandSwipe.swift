import Foundation

/// The math of the two-finger swipe between islands, free of AppKit so it can be tested. The view
/// layer feeds it scroll deltas and reads back where the content should be and where the gesture ends.
public struct IslandSwipe: Equatable, Sendable {
    public enum Axis: Equatable, Sendable { case undecided, horizontal, vertical }

    /// Past this share of the width, the halfway point, a release commits even without speed.
    public static let commitFraction = 0.5
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
    /// Where the content already was when the fingers caught it, still moving from the last switch.
    /// The gesture carries on from there instead of making the content jump back under the fingers.
    public var headStart = 0.0
    /// How far the content is pulled, the head start included.
    private var position: Double { translation + headStart }
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
    private var direction: Int { position > 0 ? -1 : 1 }

    private func exists(_ index: Int) -> Bool { index >= 0 && index < islandCount }

    /// Where to draw the content: it follows the fingers one to one, and resists once there is no
    /// island on that side.
    public var offset: Double {
        guard axis == .horizontal else { return 0 }
        if exists(selectedIndex + direction) {
            return min(max(position, -width), width)
        }
        let limit = width * Self.rubberBandLimit
        return (position < 0 ? -1 : 1) * Self.rubberBand(abs(position), limit: limit)
    }

    /// How fast the content is moving in points per second, which is what it should go on with
    /// when the fingers let go: their speed where it follows them one to one, less where it
    /// resists, and none where it has stopped at the next island.
    public var contentVelocity: Double {
        guard axis == .horizontal else { return 0 }
        if exists(selectedIndex + direction) {
            return abs(position) < width ? velocity : 0
        }
        return velocity * Self.rubberBandSlope(abs(position), limit: width * Self.rubberBandLimit)
    }

    /// True while the content is past the halfway point with an island to go to, so that letting
    /// go now switches to it whatever the speed.
    public var isPastCommitPoint: Bool {
        guard axis == .horizontal, exists(selectedIndex + direction) else { return false }
        return abs(position) >= width * Self.commitFraction
    }

    /// The index the release lands on, which is the current one when the swipe falls short or has
    /// nowhere to go.
    public func settledIndex(endingVelocity: Double? = nil) -> Int {
        guard axis == .horizontal else { return selectedIndex }
        let target = selectedIndex + direction
        guard exists(target) else { return selectedIndex }
        let speed = endingVelocity ?? velocity
        // The fingers' own travel decides whether it was a flick; a head start is not a movement.
        let flicked = abs(translation) >= Self.minimumFlickDistance
            && abs(speed) >= Self.flickVelocity
            && (speed > 0) == (position > 0)
        return flicked || isPastCommitPoint ? target : selectedIndex
    }

    /// Diminishing returns toward `limit`, like a scroll view pulled past its edge.
    public static func rubberBand(_ distance: Double, limit: Double) -> Double {
        guard distance > 0, limit > 0 else { return 0 }
        return (1 - 1 / (distance * rubberBandCoefficient / limit + 1)) * limit
    }

    /// How much of the fingers' speed is left at `distance`: the slope of `rubberBand` there.
    private static func rubberBandSlope(_ distance: Double, limit: Double) -> Double {
        let resistance = distance * rubberBandCoefficient / limit + 1
        return rubberBandCoefficient / (resistance * resistance)
    }

    private static let rubberBandCoefficient = 0.55
}

/// A damped spring pulling a page offset to zero. The sidebar hands its motion to Core
/// Animation as sampled positions, so the slide keeps its frame rate while the app is busy putting
/// the new island's content on screen. The spring is linear, which is what lets the sidebar add a
/// second one on top when a switch redirects a strip that is still moving.
public struct PageSpring: Equatable, Sendable {
    public var position: Double
    /// Points per second, positive to the right.
    public var velocity: Double
    /// Seconds for one period of the undamped spring. Same meaning as SwiftUI's spring response.
    public let response: Double
    /// 1 is critically damped: the page eases into place and never passes it. Below 1 it gets
    /// there sooner and passes it by a little before it comes to rest, which reads as a snap.
    public let damping: Double

    public init(position: Double = 0, velocity: Double = 0, response: Double = 0.4, damping: Double = 1) {
        self.position = position
        self.velocity = velocity
        self.response = max(response, 0.05)
        self.damping = min(max(damping, 0.1), 1)
    }

    private var omega: Double { 2 * .pi / response }

    /// A spring overshoots when it is thrown at its rest point faster than it would get there on
    /// its own. This caps such a throw at the fastest speed with which a critically damped spring
    /// still lands without passing zero, so a hard flick never makes the page bounce further than
    /// the damping alone does. Motion away from zero is left alone; the spring turns it around.
    public mutating func limitOvershoot() {
        let towardRest = position * velocity < 0
        guard towardRest else { return }
        let limit = omega * abs(position)
        velocity = velocity < 0 ? max(velocity, -limit) : min(velocity, limit)
    }

    /// The spring `time` seconds on.
    public func advanced(by time: Double) -> PageSpring {
        let time = max(time, 0)
        let omega = omega
        let decay = exp(-damping * omega * time)
        guard damping < 1 else {
            let pull = velocity + omega * position
            return PageSpring(
                position: (position + pull * time) * decay,
                velocity: (velocity - omega * pull * time) * decay,
                response: response,
                damping: damping
            )
        }
        let frequency = omega * (1 - damping * damping).squareRoot()
        let swing = cos(frequency * time)
        let turn = sin(frequency * time) / frequency
        return PageSpring(
            position: (position * swing + (velocity + damping * omega * position) * turn) * decay,
            velocity: (velocity * swing - (damping * omega * velocity + omega * omega * position) * turn) * decay,
            response: response,
            damping: damping
        )
    }

    /// Close enough to rest that snapping the last fraction of a point is invisible.
    public var isSettled: Bool { abs(position) < 0.25 && abs(velocity) < 4 }

    /// Samples per second in `trajectory`. Twice the fastest display, so the straight lines
    /// between samples are indistinguishable from the curve.
    public static let sampleRate = 240.0

    /// The positions from now until the spring has settled, `sampleRate` of them a second, the
    /// last one at rest.
    public func trajectory() -> [Double] {
        var samples = [position]
        // Three seconds is far beyond any response the sidebar uses; it only bounds the loop.
        for step in 1...Int(3 * Self.sampleRate) {
            let next = advanced(by: Double(step) / Self.sampleRate)
            if next.isSettled { break }
            samples.append(next.position)
        }
        samples.append(0)
        return samples
    }
}
