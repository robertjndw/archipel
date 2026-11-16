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

    @Test func theTurnEndKeepsSubagentsThatAreStillRunning() {
        // Whatever is still listed at the main Stop is background work, however long it has been
        // inside one tool call.
        var activity = working()
        activity.apply(.subagentStarted(id: "quiet"), isBeingViewed: false, at: start)
        activity.apply(.subagentStarted(id: "busy"), isBeingViewed: false, at: start)
        activity.apply(.subagentActivity(id: "busy"), isBeingViewed: false, at: start + 100)
        activity.apply(.turnFinished(message: nil), isBeingViewed: false, at: start + 120)
        #expect(activity.subagents.count == 2)
        #expect(activity.status == .finished)
        #expect(activity.isBusy)
    }

    @Test func aFinishedTurnWithSubagentsRunningIsNotUnreadUntilTheLastOneLeaves() {
        var activity = working()
        activity.apply(.subagentStarted(id: "a"), isBeingViewed: false, at: start)
        activity.apply(.subagentStarted(id: "b"), isBeingViewed: false, at: start)
        activity.apply(.turnFinished(message: nil), isBeingViewed: false, at: start + 10)
        #expect(!activity.unread)
        activity.apply(.subagentFinished(id: "a"), isBeingViewed: false, at: start + 20)
        #expect(!activity.unread)
        activity.apply(.subagentFinished(id: "b"), isBeingViewed: false, at: start + 30)
        #expect(activity.unread)
        #expect(!activity.isBusy)
        #expect(activity.status == .finished)
    }

    @Test func backgroundSubagentActivityDoesNotReopenTheTurn() {
        var activity = working()
        activity.apply(.subagentStarted(id: "a"), isBeingViewed: false, at: start)
        activity.apply(.turnFinished(message: nil), isBeingViewed: false, at: start + 10)
        activity.apply(.subagentActivity(id: "a"), isBeingViewed: false, at: start + 20)
        #expect(activity.status == .finished)
        #expect(activity.completedTurn)
    }

    @Test func aSubagentsToolCallAnswersItsRequest() {
        // Inside the turn the session goes back to work, after it back to its finished turn.
        var during = working()
        during.apply(.subagentStarted(id: "a"), isBeingViewed: false, at: start)
        during.apply(.attentionRequested(.permission, message: nil), isBeingViewed: false, at: start + 5)
        during.apply(.subagentActivity(id: "a"), isBeingViewed: false, at: start + 10)
        #expect(during.status == .working)

        var after = working()
        after.apply(.subagentStarted(id: "a"), isBeingViewed: false, at: start)
        after.apply(.turnFinished(message: nil), isBeingViewed: false, at: start + 5)
        after.apply(.attentionRequested(.permission, message: nil), isBeingViewed: false, at: start + 10)
        after.apply(.subagentActivity(id: "a"), isBeingViewed: false, at: start + 15)
        #expect(after.status == .finished)
    }

    @Test func aSubagentActivityAloneDoesNotStartWork() {
        var activity = SessionActivity(status: .finished)
        activity.apply(.subagentActivity(id: "a"), isBeingViewed: false, at: start)
        #expect(activity.status == .finished)
        #expect(activity.subagents.count == 1)
    }

    @Test func aTimerExpiresAQuietSubagentAndSettlesTheTurn() {
        var activity = working()
        activity.apply(.subagentStarted(id: "lost"), isBeingViewed: false, at: start)
        activity.apply(.turnFinished(message: nil), isBeingViewed: false, at: start + 10)
        #expect(activity.subagents.nextExpiry == start + SubagentRoster.quietLimit)
        activity.expireSubagents(at: start + SubagentRoster.quietLimit - 1)
        #expect(activity.subagents.count == 1)
        activity.expireSubagents(at: start + SubagentRoster.quietLimit)
        #expect(activity.subagents.count == 0)
        #expect(activity.subagents.nextExpiry == nil)
        #expect(activity.unread)
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
