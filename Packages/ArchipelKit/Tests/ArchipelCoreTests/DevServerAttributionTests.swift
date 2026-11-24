import Foundation
import Testing
@testable import ArchipelCore

struct DevServerAttributionTests {
    private func verdict(_ session: String, _ port: Int, _ listeners: [String: Set<Int>], settled: Bool = false) -> DevServerAttribution.Verdict {
        DevServerAttribution.verdict(for: session, port: port, listeners: listeners, isSettled: settled)
    }

    @Test func ownListenerIsAcceptedRightAway() {
        #expect(verdict("a", 5173, ["a": [5173], "b": [3000]]) == .accept)
    }

    @Test func anotherSessionsListenerVetoes() {
        // Tab B prints the URL of the server tab A runs.
        #expect(verdict("b", 5173, ["a": [5173], "b": []]) == .veto)
        #expect(verdict("b", 5173, ["a": [5173]], settled: true) == .veto)
    }

    @Test func listenerNoTabOwnsIsAcceptedOnceTheScanHadItsChance() {
        // docker compose up: the socket belongs to the Docker VM, not to anything in the tab.
        #expect(verdict("a", 8080, ["a": [], "b": [3000]]) == .wait)
        #expect(verdict("a", 8080, ["a": [], "b": [3000]], settled: true) == .accept)
        #expect(verdict("a", 8080, [:], settled: true) == .accept)
    }

    @Test func settlesAfterOneScanInterval() {
        let start = ContinuousClock.now
        #expect(!DevServerAttribution.isSettled(openSince: start, resumedAt: nil, now: start))
        #expect(!DevServerAttribution.isSettled(openSince: start, resumedAt: nil, now: start.advanced(by: .seconds(4))))
        #expect(DevServerAttribution.isSettled(openSince: start, resumedAt: nil, now: start.advanced(by: .seconds(5))))
    }

    @Test func returningToTheFrontWaitsForTheSlowBackgroundScan() {
        let start = ContinuousClock.now
        let resumed = start.advanced(by: .seconds(30))
        // Open long before, but the scan data on return can be from before the server started.
        #expect(!DevServerAttribution.isSettled(openSince: start, resumedAt: resumed, now: resumed.advanced(by: .seconds(10))))
        #expect(DevServerAttribution.isSettled(openSince: start, resumedAt: resumed, now: resumed.advanced(by: .seconds(16))))
    }
}
