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

    @Test func caughtContentCarriesOnFromWhereItWas() {
        var gesture = IslandSwipe(islandCount: 3, selectedIndex: 1, width: 260)
        gesture.headStart = -120
        gesture.update(dx: -4, dy: 0, time: 0)
        gesture.update(dx: -4, dy: 0, time: 0.016)
        #expect(gesture.axis == .horizontal)
        #expect(abs(gesture.offset - -128) < 0.001)
    }

    @Test func aHeadStartPastTheCommitPointCommitsOnRelease() {
        var gesture = IslandSwipe(islandCount: 3, selectedIndex: 1, width: 260)
        gesture.headStart = -120
        for step in 0..<5 { gesture.update(dx: -2, dy: 0, time: Double(step)) }
        #expect(gesture.settledIndex() == 2)
    }

    @Test func aHeadStartAloneIsNoFlick() {
        // Barely moved, slowly: only the distance may decide, and 40pt falls short.
        var gesture = IslandSwipe(islandCount: 3, selectedIndex: 1, width: 260)
        gesture.headStart = 34
        for step in 0..<3 { gesture.update(dx: 2, dy: 0, time: Double(step)) }
        #expect(gesture.settledIndex() == 1)
    }
}

struct PageSpringTests {
    private func run(_ spring: inout PageSpring, seconds: Double, fps: Double = 120, check: (PageSpring) -> Void = { _ in }) {
        for _ in 0..<Int(seconds * fps) {
            spring.step(1 / fps)
            check(spring)
        }
    }

    @Test func settlesWithoutOvershootFromRest() {
        var spring = PageSpring(position: 260, response: 0.4)
        run(&spring, seconds: 1) { #expect($0.position >= -0.01) }
        #expect(spring.isSettled)
    }

    @Test func aHardFlickIsLimitedSoItNeverPassesZero() {
        var spring = PageSpring(position: 150, velocity: -6000, response: 0.4)
        spring.limitOvershoot()
        #expect(spring.velocity > -6000)
        run(&spring, seconds: 1.2) { #expect($0.position >= -0.5) }
        #expect(spring.isSettled)
    }

    @Test func motionAwayFromRestIsKeptAndTurnedAround() {
        var spring = PageSpring(position: 100, velocity: 800, response: 0.4)
        spring.limitOvershoot()
        #expect(spring.velocity == 800)
        var peak = 0.0
        run(&spring, seconds: 1.5) { peak = max(peak, $0.position) }
        #expect(peak > 100)
        #expect(spring.isSettled)
    }

    @Test func frameRateDoesNotChangeTheMotion() {
        var slow = PageSpring(position: 260, response: 0.4)
        var fast = slow
        run(&slow, seconds: 0.2, fps: 60)
        run(&fast, seconds: 0.2, fps: 120)
        #expect(abs(slow.position - fast.position) < 0.5)
    }

    @Test func aLongFrameDoesNotJump() {
        var spring = PageSpring(position: 260, response: 0.4)
        spring.step(5)
        #expect(spring.position > 100)
    }
}
