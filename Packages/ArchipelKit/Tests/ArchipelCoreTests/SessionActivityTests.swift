import Testing
@testable import ArchipelCore

struct SessionActivityTests {
    struct Row: CustomTestStringConvertible {
        var from: SessionStatus
        var event: AgentEvent
        var to: SessionStatus
        var testDescription: String { "\(from) + \(event) -> \(to)" }
    }

    static let transitions: [Row] = [
        Row(from: .notStarted, event: .launched, to: .starting),
        Row(from: .starting, event: .sessionStarted, to: .finished),
        Row(from: .notStarted, event: .sessionStarted, to: .finished),
        Row(from: .working, event: .sessionStarted, to: .working),
        Row(from: .needsAttention(.permission), event: .sessionStarted, to: .needsAttention(.permission)),
        Row(from: .finished, event: .promptSubmitted, to: .working),
        Row(from: .needsAttention(.permission), event: .promptSubmitted, to: .working),
        Row(from: .needsAttention(.question), event: .activity, to: .working),
        Row(from: .working, event: .attentionRequested(.permission, message: nil), to: .needsAttention(.permission)),
        Row(from: .working, event: .turnFinished(message: nil), to: .finished),
        Row(from: .working, event: .terminalNotification(title: "t", body: "b"), to: .needsAttention(.question)),
        Row(from: .starting, event: .terminalNotification(title: "t", body: "b"), to: .needsAttention(.question)),
        Row(from: .needsAttention(.permission), event: .terminalNotification(title: "t", body: "b"), to: .needsAttention(.permission)),
        Row(from: .finished, event: .terminalNotification(title: "t", body: "b"), to: .finished),
        Row(from: .notStarted, event: .terminalNotification(title: "t", body: "b"), to: .notStarted),
        Row(from: .working, event: .bell, to: .working),
        Row(from: .working, event: .processExited(code: 2), to: .exited(code: 2)),
        Row(from: .exited(code: 0), event: .activity, to: .exited(code: 0)),
        Row(from: .exited(code: 0), event: .turnFinished(message: nil), to: .exited(code: 0)),
        Row(from: .exited(code: 1), event: .launched, to: .starting),
        Row(from: .working, event: .agentLeft, to: .finished),
        Row(from: .needsAttention(.permission), event: .agentLeft, to: .finished),
        Row(from: .finished, event: .agentLeft, to: .finished),
        Row(from: .exited(code: 0), event: .agentLeft, to: .exited(code: 0)),
    ]

    @Test(arguments: transitions)
    func transition(_ row: Row) {
        var activity = SessionActivity(status: row.from)
        activity.apply(row.event, isBeingViewed: true)
        #expect(activity.status == row.to)
    }

    @Test func messagesAreStored() {
        var activity = SessionActivity(status: .working)
        activity.apply(.attentionRequested(.permission, message: "run rm?"), isBeingViewed: true)
        #expect(activity.lastMessage == "run rm?")
        activity.apply(.turnFinished(message: "done"), isBeingViewed: true)
        #expect(activity.lastMessage == "done")
        activity.apply(.terminalNotification(title: "t", body: "body"), isBeingViewed: true)
        #expect(activity.lastMessage == "body")
        #expect(activity.status == .finished)
    }

    @Test func unreadEvenWhenOnScreen() {
        // The window can be open with nobody in front of it.
        for event in [
            AgentEvent.attentionRequested(.question, message: nil),
            .turnFinished(message: nil),
            .processExited(code: 0),
            .processExited(code: 1),
        ] {
            for onScreen in [false, true] {
                var activity = SessionActivity(status: .working)
                activity.apply(event, isBeingViewed: onScreen)
                #expect(activity.unread, "\(event), on screen: \(onScreen)")
            }
        }
    }

    @Test func aNewPromptClearsUnread() {
        var activity = SessionActivity(status: .working)
        activity.apply(.turnFinished(message: nil), isBeingViewed: false)
        #expect(activity.unread)
        activity.apply(.promptSubmitted, isBeingViewed: false)
        #expect(!activity.unread)
        #expect(activity.status == .working)
    }

    @Test func workingAndStartingNeverMarkUnread() {
        var activity = SessionActivity()
        activity.apply(.launched, isBeingViewed: false)
        activity.apply(.sessionStarted, isBeingViewed: false)
        activity.apply(.promptSubmitted, isBeingViewed: false)
        #expect(!activity.unread)
    }

    @Test func bellOnlyMarksUnread() {
        var activity = SessionActivity(status: .working)
        activity.apply(.bell, isBeingViewed: false)
        #expect(activity.unread)
        #expect(activity.status == .working)

        var viewed = SessionActivity(status: .working)
        viewed.apply(.bell, isBeingViewed: true)
        #expect(!viewed.unread)
    }

    @Test func markViewedKeepsStatus() {
        var activity = SessionActivity(status: .working)
        activity.apply(.attentionRequested(.permission, message: nil), isBeingViewed: false)
        activity.markViewed()
        #expect(!activity.unread)
        #expect(activity.status == .needsAttention(.permission))
    }

    @Test func needsUser() {
        #expect(SessionActivity(status: .needsAttention(.question)).needsUser)
        #expect(!SessionActivity(status: .finished).needsUser)
    }

    @Test func relaunchResetsExitedSession() {
        var activity = SessionActivity(status: .exited(code: 1), unread: true, lastMessage: "old")
        activity.apply(.launched, isBeingViewed: false)
        #expect(activity == SessionActivity(status: .starting))
    }

    @Test func onlyAFinishedTurnCountsAsDone() {
        var activity = SessionActivity()
        activity.apply(.launched, isBeingViewed: true)
        activity.apply(.sessionStarted, isBeingViewed: true)
        #expect(activity.status == .finished)
        #expect(!activity.completedTurn)

        activity.apply(.promptSubmitted, isBeingViewed: true)
        activity.apply(.turnFinished(message: nil), isBeingViewed: true)
        #expect(activity.completedTurn)

        activity.apply(.promptSubmitted, isBeingViewed: true)
        #expect(!activity.completedTurn)
        activity.apply(.turnFinished(message: nil), isBeingViewed: true)
        activity.apply(.launched, isBeingViewed: true)
        #expect(!activity.completedTurn)
    }

    @Test func backgroundTasksDoNotHoldBackAFinishedTurn() {
        var activity = SessionActivity(status: .working)
        activity.apply(.turnFinished(message: "Server is up", backgroundTasks: 1), isBeingViewed: false)
        #expect(activity.backgroundTasks == 1)
        // A dev server never exits, so the result has to be announced regardless.
        #expect(activity.unread)
        #expect(!activity.isBusy)
        #expect(activity.hasWorkInFlight)
    }

    @Test func backgroundTasksFollowTheLatestReport() {
        var activity = SessionActivity(status: .working)
        activity.apply(.turnFinished(message: nil, backgroundTasks: 2), isBeingViewed: false)
        // StopFailure and Codex say nothing about background work.
        activity.apply(.turnFinished(message: nil), isBeingViewed: false)
        #expect(activity.backgroundTasks == 2)
        activity.apply(.turnFinished(message: nil, backgroundTasks: 0), isBeingViewed: false)
        #expect(activity.backgroundTasks == 0)
        #expect(!activity.hasWorkInFlight)

        activity.apply(.turnFinished(message: nil, backgroundTasks: 1), isBeingViewed: false)
        activity.apply(.processExited(code: 0), isBeingViewed: false)
        #expect(activity.backgroundTasks == 0)
    }

    @Test func agentLeavingAShellDropsItsTurnAndWork() {
        var activity = SessionActivity(status: .working)
        activity.apply(.subagentStarted(id: "a"), isBeingViewed: false)
        activity.apply(.turnFinished(message: "done", backgroundTasks: 2), isBeingViewed: false)
        #expect(activity.completedTurn)

        activity.apply(.agentLeft, isBeingViewed: false)
        #expect(activity.status == .finished)
        // The shell prompt has no turn to show, and the agent's background tasks went with it.
        #expect(!activity.completedTurn)
        #expect(activity.subagents.count == 0)
        #expect(activity.backgroundTasks == 0)
        #expect(!activity.hasWorkInFlight)
    }
}
