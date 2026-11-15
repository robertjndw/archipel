import Foundation
import Testing
@testable import ArchipelCore

struct SubagentRosterTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func working() -> SessionActivity {
        var activity = SessionActivity()
        activity.apply(.launched, isBeingViewed: false, at: start)
        activity.apply(.promptSubmitted, isBeingViewed: false, at: start)
        return activity
    }

    @Test func countsStartedUntilStopped() {
        var activity = working()
        activity.apply(.subagentStarted(id: "a"), isBeingViewed: false, at: start)
        activity.apply(.subagentStarted(id: "b"), isBeingViewed: false, at: start)
        activity.apply(.subagentStarted(id: "a"), isBeingViewed: false, at: start)
        #expect(activity.subagents.count == 2)
        activity.apply(.subagentFinished(id: "a"), isBeingViewed: false, at: start + 5)
        #expect(activity.subagents.count == 1)
        #expect(activity.status == .working)
    }

    @Test func theTurnEndClearsQuietSubagentsButKeepsBusyOnes() {
        var activity = working()
        activity.apply(.subagentStarted(id: "lost"), isBeingViewed: false, at: start)
        activity.apply(.subagentStarted(id: "background"), isBeingViewed: false, at: start)
        activity.apply(.subagentActivity(id: "background"), isBeingViewed: false, at: start + 100)
        activity.apply(.turnFinished(message: nil), isBeingViewed: false, at: start + 120)
        #expect(activity.subagents.count == 1)
    }

    @Test func aDroppedSubagentReturnsWithItsNextToolCall() {
        var activity = working()
        activity.apply(.subagentActivity(id: "background"), isBeingViewed: false, at: start)
        #expect(activity.subagents.count == 1)
    }

    @Test func expiresAfterLongQuiet() {
        var activity = working()
        activity.apply(.subagentStarted(id: "a"), isBeingViewed: false, at: start)
        activity.apply(.activity, isBeingViewed: false, at: start + 11 * 60)
        #expect(activity.subagents.count == 0)
    }

    @Test func aRestartOrExitClearsTheRoster() {
        var activity = working()
        activity.apply(.subagentStarted(id: "a"), isBeingViewed: false, at: start)
        activity.apply(.processExited(code: 0), isBeingViewed: false, at: start)
        #expect(activity.subagents.count == 0)
        activity.apply(.launched, isBeingViewed: false, at: start)
        activity.apply(.subagentStarted(id: "b"), isBeingViewed: false, at: start)
        activity.apply(.launched, isBeingViewed: false, at: start)
        #expect(activity.subagents.count == 0)
    }

    @Test func subagentStopDoesNotFinishTheTurn() {
        var activity = working()
        activity.apply(.subagentFinished(id: "a"), isBeingViewed: false, at: start)
        #expect(activity.status == .working)
        #expect(!activity.unread)
    }
}
