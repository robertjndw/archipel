import Testing
@testable import ArchipelCore

struct IslandSwipeTests {
    private func swipe(index: Int = 1, count: Int = 3, dx: Double, dy: Double = 0, steps: Int = 5, duration: Double = 0.5) -> IslandSwipe {
        var gesture = IslandSwipe(islandCount: count, selectedIndex: index, width: 260)
        for step in 0..<steps {
            gesture.update(dx: dx / Double(steps), dy: dy / Double(steps), time: duration * Double(step) / Double(steps))
        }
        return gesture
    }

    @Test func verticalGesturesAreIgnoredForGood() {
        var gesture = swipe(dx: 10, dy: 60)
        #expect(gesture.axis == .vertical)
        gesture.update(dx: 200, dy: 0, time: 1)
        #expect(gesture.offset == 0)
        #expect(gesture.settledIndex() == 1)
    }

    @Test func horizontalContentFollowsTheFingers() {
        let gesture = swipe(dx: 80)
        #expect(gesture.axis == .horizontal)
        #expect(abs(gesture.offset - 80) < 0.001)
    }

    @Test func shortSlowDragSnapsBack() {
        #expect(swipe(dx: 40, duration: 1).settledIndex() == 1)
    }

    @Test func farDragCommitsInTheSwipeDirection() {
        #expect(swipe(dx: 100, duration: 1).settledIndex() == 0)
        #expect(swipe(dx: -100, duration: 1).settledIndex() == 2)
    }

    @Test func fastFlickCommitsOverAShortDistance() {
        #expect(swipe(dx: -50, duration: 0.1).settledIndex() == 2)
    }

    @Test func flickAgainstTheDragDoesNotCommit() {
        let gesture = swipe(dx: 60, duration: 1)
        #expect(gesture.settledIndex(endingVelocity: -900) == 1)
    }

    @Test func edgesResistAndNeverCommit() {
        let first = swipe(index: 0, dx: 300, duration: 0.2)
        #expect(first.offset > 0 && first.offset < 260 * IslandSwipe.rubberBandLimit)
        #expect(first.settledIndex() == 0)
        let last = swipe(index: 2, dx: -300, duration: 0.2)
        #expect(last.offset < 0 && last.offset > -260 * IslandSwipe.rubberBandLimit)
        #expect(last.settledIndex() == 2)
    }

    @Test func rubberBandIsMonotonicAndBounded() {
        var previous = 0.0
        for distance in stride(from: 10.0, through: 2000, by: 50) {
            let value = IslandSwipe.rubberBand(distance, limit: 80)
            #expect(value > previous && value < 80)
            previous = value
        }
    }

    @Test func singleIslandNeverMoves() {
        #expect(swipe(index: 0, count: 1, dx: -200, duration: 0.1).settledIndex() == 0)
    }
}

struct SplitSnapTests {
    @Test func snapsWithinThreshold() {
        let result = SplitSnap.resolve(position: 497, total: 1001, thickness: 1)
        #expect(result.snapped && result.position == 500)
    }

    @Test func leavesFarPositionsAlone() {
        let result = SplitSnap.resolve(position: 300, total: 1001, thickness: 1)
        #expect(!result.snapped && result.position == 300)
    }
}

struct FinishPulseTests {
    @Test func playsWhenATurnEndsUnseen() {
        #expect(FinishPulse.shouldPlay(from: .working, to: .finished, isBeingViewed: false))
        #expect(FinishPulse.shouldPlay(from: .needsAttention(.question), to: .finished, isBeingViewed: false))
    }

    @Test func staysQuietWhenSeenOrNotAResult() {
        #expect(!FinishPulse.shouldPlay(from: .working, to: .finished, isBeingViewed: true))
        #expect(!FinishPulse.shouldPlay(from: .starting, to: .finished, isBeingViewed: false))
        #expect(!FinishPulse.shouldPlay(from: .notStarted, to: .finished, isBeingViewed: false))
        #expect(!FinishPulse.shouldPlay(from: .working, to: .needsAttention(.permission), isBeingViewed: false))
    }
}
