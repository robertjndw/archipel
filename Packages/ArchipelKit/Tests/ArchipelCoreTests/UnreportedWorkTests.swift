import Testing
@testable import ArchipelCore

struct UnreportedWorkTests {
    private let hookless = UnreportedWork.Occupant.agent(reportsLifecycleThroughHooks: false)

    /// An agent the app launched and counted as up once its terminal was, as it does for one
    /// that has no hook for its start.
    private func startedAgent() -> SessionActivity {
        var activity = SessionActivity()
        activity.apply(.launched, isBeingViewed: true)
        activity.apply(.sessionStarted, isBeingViewed: true)
        return activity
    }

    private func find(_ occupant: UnreportedWork.Occupant, _ activity: SessionActivity, alive: Bool = true) -> UnreportedWork? {
        UnreportedWork.find(in: occupant, activity: activity, processIsAlive: alive) {
            Issue.record("Only a shell is asked what runs in front of it.")
            return nil
        }
    }

    @Test func anIdleAgentWithoutHooksHasNothingToLose() {
        #expect(find(hookless, startedAgent()) == nil)
    }

    @Test func aTurnEndWithoutAnyInputStillLeavesNothingToLose() {
        // What a notify payload alone does: the turn was never reported to begin.
        var activity = startedAgent()
        activity.apply(.turnFinished(message: "Done."), isBeingViewed: true)
        #expect(find(hookless, activity) == nil)
    }

    @Test func inputSinceLaunchMayBeATurn() {
        var activity = startedAgent()
        activity.inputSubmitted()
        #expect(find(hookless, activity) == .agentTurn)
    }

    @Test func aReportedTurnEndSettlesTheInput() {
        var activity = startedAgent()
        activity.inputSubmitted()
        activity.apply(.turnFinished(message: nil), isBeingViewed: true)
        #expect(find(hookless, activity) == nil)
    }

    @Test func inputAfterATurnEndMayBeTheNextTurn() {
        var activity = startedAgent()
        activity.inputSubmitted()
        activity.apply(.turnFinished(message: nil), isBeingViewed: true)
        activity.inputSubmitted()
        #expect(find(hookless, activity) == .agentTurn)
    }

    @Test func anApprovalRequestDoesNotEndTheTurn() {
        var activity = startedAgent()
        activity.inputSubmitted()
        activity.apply(.attentionRequested(.permission, message: nil), isBeingViewed: true)
        // Looking at the session is all the app learns about the answer.
        activity.status = .finished
        #expect(find(hookless, activity) == .agentTurn)
    }

    @Test func aRelaunchForgetsTheInput() {
        var activity = startedAgent()
        activity.inputSubmitted()
        activity.apply(.launched, isBeingViewed: true)
        #expect(!activity.awaitsTurnEnd)
        #expect(find(hookless, activity) == nil)
    }

    @Test func anExitedProcessIsNeverWaitedOn() {
        var activity = startedAgent()
        activity.inputSubmitted()
        activity.apply(.processExited(code: 0), isBeingViewed: true)
        #expect(!activity.awaitsTurnEnd)
        // Return on the exited terminal restarts it and is not input to the agent.
        activity.inputSubmitted()
        #expect(!activity.awaitsTurnEnd)
    }

    @Test func anAgentLeavingItsShellTakesItsTurnAlong() {
        var activity = startedAgent()
        activity.inputSubmitted()
        activity.apply(.agentLeft, isBeingViewed: true)
        #expect(!activity.awaitsTurnEnd)
    }

    @Test func hooksAccountForEveryTurn() {
        var activity = startedAgent()
        activity.inputSubmitted()
        #expect(find(.agent(reportsLifecycleThroughHooks: true), activity) == nil)
    }

    @Test func nothingIsLostOnceTheProcessIsGone() {
        var activity = startedAgent()
        activity.inputSubmitted()
        #expect(find(hookless, activity, alive: false) == nil)
        #expect(find(.script, activity, alive: false) == nil)
        let shell = UnreportedWork.find(in: .shell, activity: activity, processIsAlive: false) { "npm run dev" }
        #expect(shell == nil)
    }

    @Test func aScriptAlwaysCounts() {
        #expect(find(.script, SessionActivity()) == .script)
    }

    @Test func aShellAsksItsForeground() {
        let busy = UnreportedWork.find(in: .shell, activity: SessionActivity(), processIsAlive: true) { "npm run dev" }
        #expect(busy == .command("npm run dev"))
        let atPrompt = UnreportedWork.find(in: .shell, activity: SessionActivity(), processIsAlive: true) { nil }
        #expect(atPrompt == nil)
    }
}
