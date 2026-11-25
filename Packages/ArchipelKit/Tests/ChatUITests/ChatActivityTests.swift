import ACPKit
@testable import ChatUI
import Foundation
import Testing

@Suite
struct WorkingStatusTests {
    private let prompt = ChatItem.userMessage(ChatMessage(id: "u", text: "prompt"))

    private func call(
        _ id: String, _ kind: ToolKind, _ status: ToolCallStatus = .inProgress, title: String? = nil, path: String? = nil,
        command: String? = nil
    ) -> ChatItem {
        .toolCall(ToolCall(
            toolCallId: id, title: title ?? "call \(id)", kind: kind, status: status,
            locations: path.map { [ToolCallLocation(path: $0)] } ?? [],
            rawInput: command.map { ["command": .string($0)] }
        ))
    }

    private func phrase(_ items: [ChatItem], cancelling: Bool = false) -> String {
        WorkingStatus.phrase(items: items, isCancelling: cancelling)
    }

    @Test func workingBeforeAnythingCameBackAndBetweenSteps() {
        #expect(phrase([]) == "Working")
        #expect(phrase([prompt]) == "Working")
        #expect(phrase([prompt, call("a", .read, .completed, path: "/p/A.swift")]) == "Working")
        #expect(phrase([prompt, .agentMessage(ChatMessage(id: "m", text: "On it."))]) == "Working")
    }

    @Test func thinkingWhileAThoughtIsTheNewestThing() {
        #expect(phrase([prompt, .agentThought(ChatMessage(id: "t", text: "Hm"))]) == "Thinking")
        #expect(phrase([prompt, .agentThought(ChatMessage(id: "t", text: "Hm")), .agentMessage(ChatMessage(id: "m", text: "So"))]) == "Working")
    }

    @Test func aRunningCallRightAboveTheLineIsNamedByItsKindOnly() {
        // Its row already reads "Read ChatView.swift"; the line must not say the file again.
        #expect(phrase([prompt, call("a", .read, path: "/p/ChatView.swift")]) == "Reading")
        #expect(phrase([prompt, call("a", .edit, path: "/p/ChatView.swift")]) == "Editing")
        #expect(phrase([prompt, call("a", .execute, command: "swift build")]) == "Running")
        #expect(phrase([prompt, call("a", .search)]) == "Searching")
        #expect(phrase([prompt, call("a", .fetch)]) == "Fetching")
        #expect(phrase([prompt, call("a", .think)]) == "Thinking")
        #expect(phrase([prompt, call("a", .other)]) == "Working")
        // A call that waits to start is as much what the turn is at as one that runs.
        #expect(phrase([prompt, call("a", .read, .pending, path: "/p/ChatView.swift")]) == "Reading")
    }

    @Test func aRunningCallBehindNewerRowsIsNamedInFull() {
        let reading = call("a", .read, path: "/p/Sources/ChatView.swift")
        let done = call("b", .search, .completed)
        #expect(phrase([prompt, reading, done]) == "Reading ChatView.swift")
        #expect(phrase([prompt, reading, .agentMessage(ChatMessage(id: "m", text: "Meanwhile"))]) == "Reading ChatView.swift")
        #expect(phrase([prompt, call("a", .execute, command: "swift build -c release\necho done"), done]) == "Running swift build -c release")
        #expect(phrase([prompt, call("a", .other, title: "Ask the reviewer"), done]) == "Ask the reviewer")
        // Without a file to name, the kind is all there is to say.
        #expect(phrase([prompt, call("a", .read), done]) == "Reading")
        // The newest of several is the one named.
        #expect(phrase([prompt, reading, call("c", .edit, path: "/p/B.swift"), done]) == "Editing B.swift")
    }

    @Test func callsLeftRunningByAnEarlierTurnDoNotCount() {
        let stale = call("a", .read, path: "/p/Old.swift")
        #expect(phrase([prompt, stale, prompt]) == "Working")
        #expect(phrase([prompt, stale, prompt, call("b", .search, .completed)]) == "Working")
    }

    @Test func stoppingWinsOverEverything() {
        #expect(phrase([prompt, call("a", .read, path: "/p/A.swift")], cancelling: true) == "Stopping")
        #expect(phrase([prompt], cancelling: true) == "Stopping")
    }

    @Test func theLineShowsForTheWholeTurnExceptWhileAskingThePermission() {
        #expect(WorkingStatus.isShown(isTurnRunning: true, isAwaitingPermission: false))
        #expect(!WorkingStatus.isShown(isTurnRunning: true, isAwaitingPermission: true))
        #expect(!WorkingStatus.isShown(isTurnRunning: false, isAwaitingPermission: false))
    }

    @Test func theLineStandsApartFromStepsAndKeepsATurnsDistances() {
        let user = ChatRow.user(ChatMessage(id: "u", text: "u"))
        let tools = ChatRow.tools(id: "tool:a", calls: [])
        let thought = ChatRow.thought(ChatMessage(id: "t", text: "t"), isStreaming: true)
        #expect(ChatRow.statusSpacing(after: nil) == 0)
        #expect(ChatRow.statusSpacing(after: user) == tools.spacing(after: user))
        #expect(ChatRow.statusSpacing(after: tools) > 0)
        #expect(ChatRow.statusSpacing(after: tools) == ChatRow.statusSpacing(after: thought))
    }

    @Test func underAReplyTheLineTakesTheRoomOfTheCopyButtonThatFollowsIt() {
        // The transcript rests on its last line. Were the two slots of different heights,
        // everything on screen would move when the turn ends.
        let reply = ChatRow.agent(ChatMessage(id: "m", text: "m"), isStreaming: true, endsTurn: false)
        #expect(ChatRow.statusSpacing(after: reply) + ChatMetrics.activityRowHeight == ChatMetrics.replyFooterHeight)
    }

    @Test func aCallTheUserRejectedIsNoLongerWhatTheTurnIsAt() {
        let rejected = call("a", .execute, .cancelled, command: "rm -rf build")
        #expect(phrase([prompt, rejected, .agentMessage(ChatMessage(id: "m", text: "All right, I will leave it."))]) == "Working")
    }
}

@Suite
struct ElapsedTimeTests {
    @Test func secondsThenMinutesThenHours() {
        #expect(ElapsedTime.text(seconds: 0) == "0s")
        #expect(ElapsedTime.text(seconds: 8) == "8s")
        #expect(ElapsedTime.text(seconds: 59) == "59s")
        #expect(ElapsedTime.text(seconds: 60) == "1m 00s")
        #expect(ElapsedTime.text(seconds: 72) == "1m 12s")
        #expect(ElapsedTime.text(seconds: 3599) == "59m 59s")
        #expect(ElapsedTime.text(seconds: 3600) == "1h 00m")
        #expect(ElapsedTime.text(seconds: 3600 + 4 * 60 + 59) == "1h 04m")
        #expect(ElapsedTime.text(seconds: 25 * 3600 + 30 * 60) == "25h 30m")
    }

    @Test func theSmallerUnitKeepsItsWidth() {
        #expect(ElapsedTime.text(seconds: 69).count == ElapsedTime.text(seconds: 70).count)
        #expect(ElapsedTime.text(seconds: 3600 + 9 * 60).count == ElapsedTime.text(seconds: 3600 + 10 * 60).count)
    }

    @Test func aNegativeTimeReadsAsZero() {
        #expect(ElapsedTime.text(seconds: -3) == "0s")
    }

    @Test func theLabelCountsWholeSecondsAndForgivesATickThatLandsAHairEarly() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(ElapsedTime.seconds(since: anchor, at: anchor) == 0)
        #expect(ElapsedTime.seconds(since: anchor, at: anchor.addingTimeInterval(72.9)) == 72)
        // The tick for the eighth second, a few milliseconds before it is over.
        #expect(ElapsedTime.seconds(since: anchor, at: anchor.addingTimeInterval(7.97)) == 8)
        // An anchor that lies ahead, after a wait was taken off, is no negative time.
        #expect(ElapsedTime.seconds(since: anchor, at: anchor.addingTimeInterval(-3)) == 0)
    }

    @Test func spokenInWordsWithoutSecondsPastAnHour() {
        let english = Locale(identifier: "en_US")
        #expect(ElapsedTime.spoken(seconds: 8, locale: english) == "8 seconds")
        #expect(ElapsedTime.spoken(seconds: 72, locale: english) == "1 minute, 12 seconds")
        #expect(ElapsedTime.spoken(seconds: 3600 + 4 * 60 + 59, locale: english) == "1 hour, 4 minutes")
    }
}

@Suite
struct TurnClockTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test func nothingRunsNothingIsTimed() {
        var clock = TurnClock()
        clock.update(turn: nil, isWaitingOnUser: false, now: start)
        #expect(clock.anchor == nil)
    }

    @Test func aTurnIsTimedFromWhenItWasFirstSeen() {
        var clock = TurnClock()
        clock.update(turn: 1, isWaitingOnUser: false, now: start)
        clock.update(turn: 1, isWaitingOnUser: false, now: at(5))
        #expect(clock.anchor == start)
    }

    @Test func timeSpentWaitingOnThePermissionDoesNotCount() {
        var clock = TurnClock()
        clock.update(turn: 1, isWaitingOnUser: false, now: start)
        clock.update(turn: 1, isWaitingOnUser: true, now: at(10))
        clock.update(turn: 1, isWaitingOnUser: true, now: at(200))
        clock.update(turn: 1, isWaitingOnUser: false, now: at(310))
        // Ten seconds worked before the card, however long the card was up.
        #expect(clock.anchor == at(300))
        // A second wait adds to the first.
        clock.update(turn: 1, isWaitingOnUser: true, now: at(320))
        clock.update(turn: 1, isWaitingOnUser: false, now: at(330))
        #expect(clock.anchor == at(310))
    }

    @Test func theNextTurnStartsOver() {
        var clock = TurnClock()
        clock.update(turn: 1, isWaitingOnUser: false, now: start)
        clock.update(turn: 1, isWaitingOnUser: true, now: at(10))
        // A queued prompt goes out the moment the turn before it ends: the number changes while
        // a turn is running all along.
        clock.update(turn: 2, isWaitingOnUser: false, now: at(60))
        #expect(clock.anchor == at(60))
        clock.update(turn: nil, isWaitingOnUser: false, now: at(70))
        #expect(clock == TurnClock())
    }

    @Test func aPreviewClockHasAlreadyRun() {
        let clock = TurnClock(turn: 0, elapsed: 72, now: at(100))
        #expect(clock.anchor == at(28))
    }
}

@Suite
struct ShimmerSweepTests {
    @Test func theBandCrossesTheWholeTextAndWaitsBeyondIt() {
        let before = ShimmerSweep.center(at: 0)
        let beyond = ShimmerSweep.center(at: ShimmerSweep.travel)
        // It starts and ends fully outside the text, so nothing is lit while it waits.
        #expect(before + ShimmerSweep.halfWidth <= 0)
        #expect(beyond - ShimmerSweep.halfWidth >= 1)
        #expect(ShimmerSweep.center(at: ShimmerSweep.period - 0.01) == beyond)
        let middle = ShimmerSweep.center(at: ShimmerSweep.travel / 2)
        #expect(abs(middle - 0.5) < 0.0001)
    }

    @Test func everyPeriodIsTheSame() {
        let time = 0.4
        #expect(abs(ShimmerSweep.center(at: time) - ShimmerSweep.center(at: time + 3 * ShimmerSweep.period)) < 0.0001)
    }
}

@MainActor @Suite
struct ChatViewStateTests {
    @Test func theClockFollowsTheSessionsTurnsAndWaits() async throws {
        let session = ChatSession(previewAgentName: "Agent", phase: .ready)
        let state = session.viewState
        state.follow(session)
        #expect(state.turnClock.anchor == nil)

        session.isTurnRunning = true
        try await waitUntil { state.turnClock.anchor != nil }
        let anchor = try #require(state.turnClock.anchor)

        // Waiting on a permission stops the clock; the answer starts it again, later than before.
        session.permissionRequests = [ChatPermissionRequest(
            id: .int(1), options: [], toolCall: ToolCall(toolCallId: "a", title: "Edit", kind: .edit, status: .pending),
            requestedToolCall: ToolCallUpdate(toolCallId: "a")
        )]
        try await Task.sleep(for: .milliseconds(30))
        session.permissionRequests = []
        try await waitUntil { (state.turnClock.anchor ?? anchor) > anchor }

        session.isTurnRunning = false
        try await waitUntil { state.turnClock.anchor == nil }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition never became true")
    }
}
