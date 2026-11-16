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
}
