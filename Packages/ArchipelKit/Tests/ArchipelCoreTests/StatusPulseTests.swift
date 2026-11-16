import Foundation
import Testing
@testable import ArchipelCore

struct StatusPulseTests {
    @Test func aFinishedTurnGlowsGreen() {
        #expect(StatusPulse.kind(from: .working, to: .finished) == .finished)
        #expect(StatusPulse.kind(from: .needsAttention(.question), to: .finished) == .finished)
    }

    @Test func aRequestGlowsOnceUntilItIsAnswered() {
        #expect(StatusPulse.kind(from: .working, to: .needsAttention(.permission)) == .needsInput)
        #expect(StatusPulse.kind(from: .finished, to: .needsAttention(.question)) == .needsInput)
        #expect(StatusPulse.kind(from: .needsAttention(.permission), to: .needsAttention(.question)) == nil)
    }

    @Test func onlyAFailedExitGlows() {
        #expect(StatusPulse.kind(from: .working, to: .exited(code: 1)) == .failed)
        #expect(StatusPulse.kind(from: .finished, to: .exited(code: 0)) == nil)
    }

    @Test func staysQuietWhenNotAResult() {
        #expect(StatusPulse.kind(from: .starting, to: .finished) == nil)
        #expect(StatusPulse.kind(from: .notStarted, to: .finished) == nil)
        #expect(StatusPulse.kind(from: .finished, to: .working) == nil)
    }

    @Test func theMostPressingWinsWhenTheyPileUp() {
        let piled: [StatusPulse] = [.finished, .needsInput, .failed]
        #expect(piled.max() == .needsInput)
    }

    // MARK: Worktree

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Applies `event` and returns the glow the worktree plays for it.
    private func pulse(_ activity: inout SessionActivity, _ event: AgentEvent, siblings: [SessionActivity] = [], at offset: TimeInterval = 0) -> StatusPulse? {
        let before = activity
        activity.apply(event, isBeingViewed: false, at: Self.start + offset)
        return StatusPulse.kind(from: before, to: activity, siblings: siblings)
    }

    private func working(subagents: [String] = []) -> SessionActivity {
        var activity = SessionActivity(status: .working)
        for id in subagents { activity.apply(.subagentStarted(id: id), isBeingViewed: false, at: Self.start) }
        return activity
    }

    @Test func aTurnEndingInAnIdleWorktreeGlows() {
        var activity = working()
        #expect(pulse(&activity, .turnFinished(message: nil), siblings: [SessionActivity(status: .finished)]) == .finished)
    }

    @Test func theMainStopWithSubagentsRunningDoesNotGlow() {
        var activity = working(subagents: ["a", "b"])
        #expect(pulse(&activity, .turnFinished(message: nil)) == nil)
        #expect(pulse(&activity, .subagentActivity(id: "a"), at: 5) == nil)
        #expect(pulse(&activity, .subagentFinished(id: "a"), at: 10) == nil)
    }

    @Test func theLastSubagentLeavingGlows() {
        var activity = working(subagents: ["a"])
        #expect(pulse(&activity, .turnFinished(message: nil)) == nil)
        #expect(pulse(&activity, .subagentFinished(id: "a"), at: 10) == .finished)
    }

    @Test func aSubagentEndingInsideTheTurnDoesNotGlow() {
        var activity = working(subagents: ["a"])
        #expect(pulse(&activity, .subagentFinished(id: "a"), at: 10) == nil)
    }

    @Test func aSiblingStillWorkingHoldsTheGlowBack() {
        var activity = working()
        #expect(pulse(&activity, .turnFinished(message: nil), siblings: [SessionActivity(status: .working)]) == nil)

        var other = working(subagents: ["a"])
        other.apply(.turnFinished(message: nil), isBeingViewed: false, at: Self.start)
        var last = working()
        #expect(pulse(&last, .turnFinished(message: nil), siblings: [other]) == nil)
    }

    @Test func aBootingSiblingDoesNotHoldTheGlowBack() {
        var activity = working()
        #expect(pulse(&activity, .turnFinished(message: nil), siblings: [SessionActivity(status: .starting)]) == .finished)
    }

    @Test func requestsAndFailuresGlowWhileTheWorktreeIsBusy() {
        let busy = [SessionActivity(status: .working)]
        var asking = working(subagents: ["a"])
        #expect(pulse(&asking, .attentionRequested(.permission, message: nil), siblings: busy) == .needsInput)
        var crashing = working(subagents: ["a"])
        #expect(pulse(&crashing, .processExited(code: 1), siblings: busy) == .failed)
    }

    @Test func gettingReadyAfterLaunchStillDoesNotGlow() {
        var activity = SessionActivity()
        #expect(pulse(&activity, .launched) == nil)
        #expect(pulse(&activity, .sessionStarted) == nil)
    }

    @Test func anExpiredSubagentGlowsLate() {
        var activity = working(subagents: ["lost"])
        activity.apply(.turnFinished(message: nil), isBeingViewed: false, at: Self.start)
        let before = activity
        activity.expireSubagents(at: Self.start + 11 * 60)
        #expect(StatusPulse.kind(from: before, to: activity, siblings: []) == .finished)
    }
}
