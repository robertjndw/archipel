import Testing
@testable import ArchipelCore

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
