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
        Row(from: .working, event: .attentionReminder(.permission, message: nil), to: .needsAttention(.permission)),
        Row(from: .needsAttention(.question), event: .attentionReminder(.permission, message: nil), to: .needsAttention(.question)),
        Row(from: .working, event: .turnInterrupted, to: .finished),
        Row(from: .needsAttention(.permission), event: .turnInterrupted, to: .finished),
        Row(from: .starting, event: .turnInterrupted, to: .starting),
        Row(from: .exited(code: 0), event: .turnInterrupted, to: .exited(code: 0)),
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

    @Test func backgroundSubagentsKeepTheSpinnerAfterTheTurnEnds() {
        var activity = SessionActivity(status: .working)
        activity.apply(.subagentStarted(id: "a"), isBeingViewed: false)
        activity.apply(.turnFinished(message: "done", backgroundTasks: nil), isBeingViewed: false)
        #expect(activity.status == .finished)
        #expect(activity.showsProgress)

        // A pending request replaces the spinner while the subagent keeps running.
        activity.apply(.attentionRequested(.permission, message: nil, subagent: "a"), isBeingViewed: false)
        #expect(!activity.showsProgress)
        activity.apply(.subagentActivity(id: "a"), isBeingViewed: false)
        #expect(activity.showsProgress)

        activity.apply(.subagentFinished(id: "a"), isBeingViewed: false)
        #expect(!activity.showsProgress)
        #expect(SessionActivity(status: .starting).showsProgress)
    }

    // MARK: Who asked

    private func turnWithSubagents(_ ids: String...) -> SessionActivity {
        var activity = SessionActivity(status: .working)
        for id in ids { activity.apply(.subagentStarted(id: id), isBeingViewed: false) }
        return activity
    }

    @Test func anotherSubagentsToolCallDoesNotAnswerARequest() {
        var activity = turnWithSubagents("a", "b")
        activity.apply(.attentionRequested(.permission, message: "Bash: make deploy", subagent: "a"), isBeingViewed: false)
        #expect(activity.pendingRequest?.requester == .subagent("a"))

        // "b" runs in parallel and keeps calling tools while "a" waits for the user.
        activity.apply(.subagentActivity(id: "b"), isBeingViewed: false)
        activity.apply(.subagentStarted(id: "c"), isBeingViewed: false)
        activity.apply(.subagentFinished(id: "b"), isBeingViewed: false)
        #expect(activity.status == .needsAttention(.permission))
        #expect(activity.lastMessage == "Bash: make deploy")

        activity.apply(.subagentActivity(id: "a"), isBeingViewed: false)
        #expect(activity.status == .working)
        #expect(activity.pendingRequests.isEmpty)
    }

    @Test func theMainAgentsToolCallDoesNotAnswerASubagentsRequest() {
        var activity = turnWithSubagents("a")
        activity.apply(.attentionRequested(.permission, message: nil, subagent: "a"), isBeingViewed: false)
        activity.apply(.activity, isBeingViewed: false)
        #expect(activity.status == .needsAttention(.permission))
        #expect(activity.needsUser)

        activity.apply(.subagentActivity(id: "a"), isBeingViewed: false)
        #expect(activity.status == .working)
    }

    @Test func aSubagentsToolCallDoesNotAnswerTheMainAgentsRequest() {
        var activity = turnWithSubagents("a")
        activity.apply(.attentionRequested(.permission, message: nil), isBeingViewed: false)
        activity.apply(.subagentActivity(id: "a"), isBeingViewed: false)
        #expect(activity.status == .needsAttention(.permission))

        // The tool that was allowed reports back.
        activity.apply(.activity, isBeingViewed: false)
        #expect(activity.status == .working)
    }

    @Test func aSubagentThatLeavesTakesItsRequestAlong() {
        var during = turnWithSubagents("a", "b")
        during.apply(.attentionRequested(.permission, message: nil, subagent: "a"), isBeingViewed: false)
        during.apply(.subagentFinished(id: "a"), isBeingViewed: false)
        #expect(during.status == .working)

        var after = turnWithSubagents("a")
        after.apply(.turnFinished(message: nil), isBeingViewed: false)
        after.apply(.attentionRequested(.permission, message: nil, subagent: "a"), isBeingViewed: false)
        after.apply(.subagentFinished(id: "a"), isBeingViewed: false)
        #expect(after.status == .finished)
        #expect(after.unread)
    }

    @Test func aRealAnswerClearsARequestWhoeverAsked() {
        for event in [AgentEvent.promptSubmitted, .turnFinished(message: nil)] {
            var activity = turnWithSubagents("a")
            activity.apply(.attentionRequested(.permission, message: nil, subagent: "a"), isBeingViewed: false)
            activity.apply(event, isBeingViewed: false)
            #expect(!activity.needsUser, "\(event)")
            #expect(activity.pendingRequests.isEmpty, "\(event)")
        }
    }

    @Test func aNewRequestReplacesWhoIsWaiting() {
        var activity = turnWithSubagents("a", "b")
        activity.apply(.attentionRequested(.permission, message: "first", subagent: "a"), isBeingViewed: false)
        activity.apply(.attentionRequested(.permission, message: "second", subagent: "b"), isBeingViewed: false)
        activity.apply(.subagentActivity(id: "a"), isBeingViewed: false)
        #expect(activity.status == .needsAttention(.permission))
        activity.apply(.subagentActivity(id: "b"), isBeingViewed: false)
        #expect(activity.status == .working)
    }

    @Test func aReminderKeepsTheRequestItFollows() {
        var activity = turnWithSubagents("a")
        activity.apply(.attentionRequested(.permission, message: "Bash: make deploy", subagent: "a"), isBeingViewed: false)
        // Claude's notification for the same prompt: less detail, and nothing about who asked.
        activity.apply(.attentionReminder(.permission, message: "Claude needs your permission to use Bash"), isBeingViewed: false)
        #expect(activity.lastMessage == "Bash: make deploy")
        #expect(activity.pendingRequest?.requester == .subagent("a"))
        activity.apply(.activity, isBeingViewed: false)
        #expect(activity.needsUser)
    }

    @Test func aReminderStandsInForAMissingRequest() {
        var activity = SessionActivity(status: .working)
        activity.apply(.attentionReminder(.permission, message: "Claude needs your permission to use Bash"), isBeingViewed: false)
        #expect(activity.status == .needsAttention(.permission))
        #expect(activity.lastMessage == "Claude needs your permission to use Bash")
        #expect(activity.unread)
    }

    // MARK: Interrupted turns

    @Test func anInterruptedTurnIsOverWithoutAResult() {
        var activity = turnWithSubagents("a")
        activity.backgroundTasks = 1
        activity.apply(.turnInterrupted, isBeingViewed: false)
        #expect(activity.status == .finished)
        #expect(!activity.completedTurn)
        // The user pressed Esc in that terminal, so there is nothing to call them back for.
        #expect(!activity.unread)
        // Subagents the turn was waiting on went with it, and nothing reports their stop.
        #expect(activity.subagents.count == 0)
        #expect(!activity.isBusy)
    }

    @Test func aDismissedRequestIsOverToo() {
        var activity = turnWithSubagents("a")
        activity.apply(.attentionRequested(.permission, message: nil, subagent: "a"), isBeingViewed: false)
        activity.markViewed()
        activity.apply(.turnInterrupted, isBeingViewed: false)
        #expect(activity.status == .finished)
        #expect(activity.pendingRequests.isEmpty)
        #expect(!activity.hasWorkInFlight)
    }

    // MARK: A request nobody claimed

    private let reminder = AgentEvent.attentionReminder(.permission, message: "Claude needs your permission to use Bash")

    @Test func anySubagentsToolCallAnswersARequestNobodyClaimed() {
        // The request hook never came, so the reminder is all there is, and it does not say that
        // it was subagent "a" asking. Its next tool call is the only sign of the answer.
        var activity = turnWithSubagents("a", "b")
        activity.apply(reminder, isBeingViewed: false)
        #expect(activity.pendingRequest?.requester == .unknown)
        activity.apply(.subagentActivity(id: "a"), isBeingViewed: false)
        #expect(activity.status == .working)
        #expect(activity.pendingRequests.isEmpty)

        var afterTheTurn = turnWithSubagents("a")
        afterTheTurn.apply(.turnFinished(message: nil), isBeingViewed: false)
        afterTheTurn.apply(reminder, isBeingViewed: false)
        afterTheTurn.apply(.subagentActivity(id: "a"), isBeingViewed: false)
        #expect(afterTheTurn.status == .finished)
    }

    @Test func theMainAgentsToolCallAnswersARequestNobodyClaimed() {
        var activity = turnWithSubagents("a")
        activity.apply(reminder, isBeingViewed: false)
        activity.apply(.activity, isBeingViewed: false)
        #expect(activity.status == .working)
    }

    @Test func aSubagentLeavingSaysNothingAboutARequestNobodyClaimed() {
        var activity = turnWithSubagents("a", "b")
        activity.apply(reminder, isBeingViewed: false)
        activity.apply(.subagentFinished(id: "b"), isBeingViewed: false)
        #expect(activity.status == .needsAttention(.permission))
    }

    @Test func theRequestItselfReplacesItsStandIn() {
        var activity = turnWithSubagents("a")
        activity.apply(reminder, isBeingViewed: false)
        activity.apply(.attentionRequested(.permission, message: "Bash: make deploy", subagent: "a"), isBeingViewed: false)
        #expect(activity.pendingRequests.map(\.requester) == [.subagent("a")])
    }

    // MARK: More than one request

    private func request(_ summary: String, from subagent: String? = nil, isPartial: Bool = false) -> AgentEvent {
        .attentionRequested(.permission, message: summary, subagent: subagent, isPartial: isPartial)
    }

    @Test func aSecondRequestIsNewsAlthoughTheStatusStays() {
        var activity = turnWithSubagents("a", "b")
        activity.apply(request("Bash: ls", from: "a"), isBeingViewed: false)
        activity.markViewed()
        let first = activity

        activity.apply(request("Bash: rm -rf build", from: "b"), isBeingViewed: false)
        #expect(activity.status == first.status)
        #expect(activity.asksSomethingNew(since: first))
        #expect(activity.unread)
        #expect(activity.pendingRequest?.summary == "Bash: rm -rf build")
        #expect(activity.pendingRequest?.requester == .subagent("b"))
        #expect(activity.pendingRequests.count == 2)
    }

    @Test func theSameRequestAgainIsNotNews() {
        var activity = turnWithSubagents("a")
        activity.apply(request("Bash: ls", from: "a"), isBeingViewed: false)
        activity.markViewed()
        let first = activity
        activity.apply(reminder, isBeingViewed: false)
        activity.apply(.subagentActivity(id: "b"), isBeingViewed: false)
        activity.apply(.bell, isBeingViewed: true)
        #expect(!activity.asksSomethingNew(since: first))
        #expect(!activity.unread)
        #expect(SessionActivity(status: .working).asksSomethingNew(since: first) == false)
        #expect(first.asksSomethingNew(since: SessionActivity(status: .working)))
    }

    @Test func aChangedSummaryFromTheSameAskerIsNews() {
        var activity = SessionActivity(status: .working)
        activity.apply(request("Bash: ls"), isBeingViewed: false)
        let first = activity
        activity.apply(request("Bash: rm -rf build"), isBeingViewed: false)
        #expect(activity.asksSomethingNew(since: first))
        // One agent shows one prompt, so its newer request is the only one.
        #expect(activity.pendingRequests.count == 1)
    }

    @Test func onlyASingleCompleteRequestCanBeAnsweredUnseen() {
        var activity = turnWithSubagents("a", "b")
        activity.apply(request("Bash: ls", from: "a"), isBeingViewed: false)
        #expect(activity.canAnswerUnseen)
        // Nothing says which of the two prompts the terminal is showing.
        activity.apply(request("Bash: rm -rf build", from: "b"), isBeingViewed: false)
        #expect(!activity.canAnswerUnseen)
        activity.apply(.subagentActivity(id: "b"), isBeingViewed: false)
        #expect(activity.canAnswerUnseen)

        var partial = SessionActivity(status: .working)
        partial.apply(request("Bash: ls…", isPartial: true), isBeingViewed: false)
        #expect(!partial.canAnswerUnseen)
        #expect(!SessionActivity(status: .working).canAnswerUnseen)
    }

    @Test func theRequestStillWaitingIsShownOnceTheNewerOneIsAnswered() {
        var activity = turnWithSubagents("a", "b")
        activity.apply(request("Bash: ls", from: "a"), isBeingViewed: false)
        activity.apply(request("Bash: rm -rf build", from: "b"), isBeingViewed: false)
        activity.markViewed()
        let both = activity

        activity.apply(.subagentActivity(id: "b"), isBeingViewed: false)
        #expect(activity.status == .needsAttention(.permission))
        #expect(activity.lastMessage == "Bash: ls")
        #expect(activity.pendingRequest?.requester == .subagent("a"))
        #expect(activity.asksSomethingNew(since: both))
        #expect(activity.unread)
    }

    @Test func answeringFromTheAppLeavesTheOtherRequestWaiting() {
        var activity = turnWithSubagents("a", "b")
        activity.apply(request("Bash: ls", from: "a"), isBeingViewed: false)
        activity.apply(request("Bash: rm -rf build", from: "b"), isBeingViewed: false)

        activity.resolveRequest(to: .working)
        #expect(activity.status == .needsAttention(.permission))
        #expect(activity.pendingRequest?.summary == "Bash: ls")
        #expect(activity.unread)

        activity.resolveRequest(to: .finished)
        #expect(activity.status == .finished)
        #expect(activity.pendingRequests.isEmpty)
        #expect(!activity.unread)
    }

    @Test func aStatusWrittenFromOutsideLeavesNoRequestBehind() {
        var activity = turnWithSubagents("a")
        activity.apply(request("Bash: ls", from: "a"), isBeingViewed: false)
        activity.status = .working
        #expect(activity.pendingRequests.isEmpty)
        // With the asker forgotten, the main agent's next request is not mistaken for a second one.
        activity.apply(request("Bash: pwd"), isBeingViewed: false)
        #expect(activity.canAnswerUnseen)
    }

    // MARK: Messages

    @Test func messagesAreMadeSafeToShow() {
        let hostile = "Done.\n\u{202E}txt.exe\u{1B}[2J\u{0}  see\tbelow"
        let shown = "Done. txt.exe [2J see below"
        var activity = SessionActivity(status: .working)
        activity.apply(.turnFinished(message: hostile), isBeingViewed: false)
        #expect(activity.lastMessage == shown)
        activity.apply(.attentionReminder(.permission, message: hostile), isBeingViewed: false)
        #expect(activity.pendingRequest?.summary == shown)
        activity.apply(.attentionRequested(.question, message: hostile + "?"), isBeingViewed: false)
        #expect(activity.lastMessage == shown + "?")
        activity.apply(.terminalNotification(title: "t", body: hostile + "!"), isBeingViewed: false)
        #expect(activity.lastMessage == shown + "!")
        #expect(SessionActivity(status: .finished, lastMessage: hostile).lastMessage == shown)
    }

    @Test func aRunawayMessageIsCutShort() {
        var activity = SessionActivity(status: .working)
        activity.apply(.turnFinished(message: String(repeating: "a", count: 50_000)), isBeingViewed: false)
        #expect(activity.lastMessage == String(repeating: "a", count: 500) + "…")
        // Nothing left to show keeps what was there.
        activity.apply(.turnFinished(message: "\u{200B}\n"), isBeingViewed: false)
        #expect(activity.lastMessage?.count == 501)
    }

    @Test func aLateInterruptionLeavesBackgroundSubagentsAlone() {
        var activity = turnWithSubagents("a")
        activity.apply(.turnFinished(message: "done"), isBeingViewed: false)
        activity.markViewed()
        let finished = activity
        activity.apply(.turnInterrupted, isBeingViewed: false)
        #expect(activity == finished)
        #expect(activity.subagents.count == 1)

        // The subagent leaving is still what announces the turn's result.
        activity.apply(.subagentFinished(id: "a"), isBeingViewed: false)
        #expect(activity.unread)
    }

    @Test func aLateInterruptionDoesNotUndoAFinishedTurn() {
        var activity = SessionActivity(status: .working)
        activity.apply(.turnFinished(message: "done"), isBeingViewed: false)
        activity.apply(.turnInterrupted, isBeingViewed: false)
        #expect(activity.status == .finished)
        #expect(activity.completedTurn)
        #expect(activity.unread)
    }
}
