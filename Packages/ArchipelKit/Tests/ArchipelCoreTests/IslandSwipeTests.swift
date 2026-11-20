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
        let gesture = swipe(dx: 60)
        #expect(gesture.axis == .horizontal)
        #expect(abs(gesture.offset - 60) < 0.001)
    }

    @Test func aSlowDragShortOfHalfwaySnapsBack() {
        #expect(swipe(dx: 40, duration: 1).settledIndex() == 1)
        // In many small steps, so that it is the distance that decides and not the speed.
        #expect(swipe(dx: -120, steps: 60, duration: 2).settledIndex() == 1)
    }

    @Test func aDragPastHalfwayCommitsInTheSwipeDirection() {
        #expect(swipe(dx: 135, duration: 2).settledIndex() == 0)
        #expect(swipe(dx: -135, duration: 2).settledIndex() == 2)
    }

    @Test func theCommitPointIsHalfwayAndOnlyWhereThereIsAnIsland() {
        #expect(!swipe(dx: -125, duration: 2).isPastCommitPoint)
        #expect(swipe(dx: -135, duration: 2).isPastCommitPoint)
        #expect(!swipe(index: 2, dx: -300, duration: 2).isPastCommitPoint)
        #expect(!swipe(dx: 10, dy: 300, duration: 2).isPastCommitPoint)
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
        gesture.headStart = -125
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

    @Test func theContentSlowsDownWhereItResists() {
        // Between two islands the content moves as fast as the fingers.
        var free = IslandSwipe(islandCount: 3, selectedIndex: 1, width: 260)
        var time = 0.0
        for _ in 0..<10 {
            time += 0.01
            free.update(dx: 6, dy: 0, time: time)
        }
        #expect(free.contentVelocity == free.velocity)

        // Past the first island it resists, so it is slower than the fingers, and letting go
        // must not make it speed up.
        var resisting = IslandSwipe(islandCount: 3, selectedIndex: 0, width: 260)
        var before = 0.0
        time = 0
        for _ in 0..<10 {
            before = resisting.offset
            time += 0.01
            resisting.update(dx: 6, dy: 0, time: time)
        }
        let lastStep = (resisting.offset - before) / 0.01
        #expect(resisting.contentVelocity > 0)
        #expect(resisting.contentVelocity < resisting.velocity / 2)
        #expect(abs(resisting.contentVelocity - lastStep) < lastStep * 0.25)
    }
}

struct PageSpringTests {
    @Test func settlesWithoutOvershootFromRest() {
        let trajectory = PageSpring(position: 260, response: 0.4).trajectory()
        #expect(trajectory.allSatisfy { $0 >= -0.01 })
        #expect(trajectory.first == 260)
        #expect(trajectory.last == 0)
        #expect(Double(trajectory.count) / PageSpring.sampleRate < 1)
    }

    @Test func aHardFlickIsLimitedSoItNeverPassesZero() {
        var spring = PageSpring(position: 150, velocity: -6000, response: 0.4)
        spring.limitOvershoot()
        #expect(spring.velocity > -6000)
        #expect(spring.trajectory().allSatisfy { $0 >= -0.5 })
        #expect(spring.advanced(by: 1.2).isSettled)
    }

    @Test func motionAwayFromRestIsKeptAndTurnedAround() {
        var spring = PageSpring(position: 100, velocity: 800, response: 0.4)
        spring.limitOvershoot()
        #expect(spring.velocity == 800)
        let trajectory = spring.trajectory()
        #expect(trajectory.max()! > 100)
        #expect(trajectory.last == 0)
        #expect(spring.advanced(by: 1.5).isSettled)
    }

    /// A switch that redirects the strip adds a spring for the way to the new island on top of
    /// the one under way. Together they must move like one spring that was redirected.
    @Test func twoSpringsAddUpToOneRedirectedSpring() {
        let underWay = PageSpring(position: -260, response: 0.4).advanced(by: 0.1)
        let added = PageSpring(position: -260, response: 0.4)
        let redirected = PageSpring(position: underWay.position - 260, velocity: underWay.velocity, response: 0.4)
        for time in [0.0, 0.05, 0.2, 0.5] {
            let sum = underWay.advanced(by: time).position + added.advanced(by: time).position
            #expect(abs(sum - redirected.advanced(by: time).position) < 1e-9)
        }
    }

    @Test(arguments: [1, 0.85]) func theVelocityIsTheSlopeOfThePosition(damping: Double) {
        let spring = PageSpring(position: 260, velocity: 500, response: 0.4, damping: damping)
        let step = 1e-5
        let slope = (spring.advanced(by: 0.1 + step).position - spring.advanced(by: 0.1 - step).position) / (2 * step)
        #expect(abs(slope - spring.advanced(by: 0.1).velocity) < 0.01)
    }

    @Test func lessDampingArrivesSoonerAndPassesByALittle() {
        let eased = PageSpring(position: 260, response: 0.3).trajectory()
        let snappy = PageSpring(position: 260, response: 0.3, damping: 0.85).trajectory()
        let arrival = { (trajectory: [Double]) in trajectory.firstIndex { abs($0) < 2 }! }
        #expect(Double(arrival(snappy)) < Double(arrival(eased)) * 0.8)
        // Enough to see it land, not enough to read as a bounce.
        #expect(snappy.min()! < -0.5)
        #expect(snappy.min()! > -3)
        #expect(snappy.last == 0)
    }

    @Test func snappySpringsAddUpToo() {
        let underWay = PageSpring(position: -260, response: 0.3, damping: 0.85).advanced(by: 0.1)
        let added = PageSpring(position: -260, response: 0.3, damping: 0.85)
        let redirected = PageSpring(position: underWay.position - 260, velocity: underWay.velocity, response: 0.3, damping: 0.85)
        for time in [0.05, 0.2, 0.5] {
            let sum = underWay.advanced(by: time).position + added.advanced(by: time).position
            #expect(abs(sum - redirected.advanced(by: time).position) < 1e-9)
        }
    }
}
