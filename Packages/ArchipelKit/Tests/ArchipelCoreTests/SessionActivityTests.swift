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

    @Test func unreadWhenNotViewed() {
        for event in [
            AgentEvent.attentionRequested(.question, message: nil),
            .turnFinished(message: nil),
            .processExited(code: 0),
            .processExited(code: 1),
        ] {
            var hidden = SessionActivity(status: .working)
            hidden.apply(event, isBeingViewed: false)
            #expect(hidden.unread, "\(event)")

            var viewed = SessionActivity(status: .working)
            viewed.apply(event, isBeingViewed: true)
            #expect(!viewed.unread, "\(event)")
        }
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
        #expect(SessionActivity(status: .needsAttention(.idle)).needsUser)
        #expect(!SessionActivity(status: .finished).needsUser)
    }

    @Test func relaunchResetsExitedSession() {
        var activity = SessionActivity(status: .exited(code: 1), unread: true, lastMessage: "old")
        activity.apply(.launched, isBeingViewed: false)
        #expect(activity == SessionActivity(status: .starting))
    }
}
