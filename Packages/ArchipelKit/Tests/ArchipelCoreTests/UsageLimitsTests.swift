import ArchipelCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

struct UsagePaceTests {
    // A 5-hour window that started two hours before `now`.
    private let window = { (percent: Double) in
        UsageWindow(usedPercent: percent, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600))
    }

    @Test func elapsedFraction() {
        #expect(window(10).elapsedFraction(at: now) == 0.4)
        #expect(UsageWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil).elapsedFraction(at: now) == nil)
    }

    @Test func runsOutBeforeTheReset() throws {
        // 80% in two hours is 40% an hour, so the last 20% go in half an hour.
        let exhaustion = try #require(window(80).projectedExhaustion(at: now))
        #expect(abs(exhaustion.timeIntervalSince(now) - 1800) < 1)
    }

    @Test func lastsUntilTheReset() {
        // 20% in two hours leaves plenty for the remaining three.
        #expect(window(20).projectedExhaustion(at: now) == nil)
        #expect(window(0).projectedExhaustion(at: now) == nil)
    }

    @Test func tooEarlyToTell() {
        let fresh = UsageWindow(usedPercent: 30, windowMinutes: 300, resetsAt: now.addingTimeInterval(299 * 60))
        #expect(fresh.projectedExhaustion(at: now) == nil)
    }
}
