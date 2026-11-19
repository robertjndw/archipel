import Foundation
import Testing
import ArchipelCore

struct ProgressTurnTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func decide(
        _ turn: ProgressTurn,
        at now: Date,
        tool: Bool = false,
        prompt: Bool = false,
        menu: Bool = false,
        status: SessionStatus = .working
    ) -> ProgressTurn.Outcome {
        turn.decide(at: now, toolProcessStartedSinceClear: tool, screenShowsPrompt: prompt, screenShowsMenu: menu, status: status)
    }

    @Test func repeatedReportsStartOnce() {
        var turn = ProgressTurn()
        #expect(turn.receive(active: true, at: start) == .started)
        #expect(turn.receive(active: true, at: start + 1) == .none)
        #expect(turn.receive(active: false, at: start + 2) == .mayHaveEnded(checkAt: start + 5))
        #expect(turn.receive(active: false, at: start + 3) == .none)
    }

    @Test func aClearWithoutASetIsNothing() {
        var turn = ProgressTurn()
        #expect(turn.receive(active: false, at: start) == .none)
        #expect(decide(turn, at: start + 10) == .ignore)
    }

    @Test func endsAfterTheQuietPeriod() {
        var turn = ProgressTurn()
        _ = turn.receive(active: true, at: start)
        _ = turn.receive(active: false, at: start + 1)
        #expect(decide(turn, at: start + 2) == .keepWorking(recheckAt: start + 4))
        #expect(decide(turn, at: start + 4) == .finished)
    }

    @Test func aFlickerDoesNotEndTheTurn() {
        var turn = ProgressTurn()
        _ = turn.receive(active: true, at: start)
        _ = turn.receive(active: false, at: start + 1)
        #expect(turn.receive(active: true, at: start + 1.2) == .started)
        #expect(decide(turn, at: start + 4) == .ignore)
    }

    @Test func somethingElseSettledItFirst() {
        var turn = ProgressTurn()
        _ = turn.receive(active: true, at: start)
        _ = turn.receive(active: false, at: start + 1)
        #expect(decide(turn, at: start + 5, status: .needsAttention(.permission)) == .ignore)
        #expect(decide(turn, at: start + 5, status: .finished) == .ignore)
    }

    @Test func aToolStartedSinceTheClearKeepsItWorking() {
        var turn = ProgressTurn()
        _ = turn.receive(active: true, at: start)
        _ = turn.receive(active: false, at: start + 10)
        #expect(decide(turn, at: start + 13, tool: true) == .keepWorking(recheckAt: start + 16))
        // An MCP server started with the agent is older than the clear; a tool call is not.
        #expect(!turn.startedSinceClear((start + 2).timeIntervalSince1970))
        #expect(turn.startedSinceClear((start + 9.5).timeIntervalSince1970))
        #expect(turn.startedSinceClear((start + 11).timeIntervalSince1970))
    }

    @Test func whatTheScreenShowsDecides() {
        var turn = ProgressTurn()
        _ = turn.receive(active: true, at: start)
        _ = turn.receive(active: false, at: start + 1)
        #expect(decide(turn, at: start + 4, prompt: true) == .needsAttention(.permission))
        #expect(decide(turn, at: start + 4, menu: true) == .needsAttention(.question))
        #expect(decide(turn, at: start + 4, tool: true, prompt: true) == .needsAttention(.permission))
    }
}
