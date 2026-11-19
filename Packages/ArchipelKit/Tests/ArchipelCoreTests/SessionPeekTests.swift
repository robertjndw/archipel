import Foundation
import Testing
@testable import ArchipelCore

struct SessionPeekTests {
    private let a = makeSession("a")
    private let b = makeSession("b")
    private let c = makeSession("c")

    @Test func prefersASessionThatNeedsTheUser() {
        let worktree = makeWorktree(sessions: [a, b, c])
        let activities: [Session.ID: SessionActivity] = [
            b.id: SessionActivity(status: .working),
            c.id: SessionActivity(status: .needsAttention(.permission)),
        ]
        let id = SessionPeek.mostRelevantSession(in: worktree, activities: activities, focusedSessionID: a.id) { _ in true }
        #expect(id == c.id)
    }

    @Test func thenABusySessionThenTheFocusedOne() {
        let worktree = makeWorktree(sessions: [a, b, c])
        let busy = SessionPeek.mostRelevantSession(
            in: worktree, activities: [b.id: SessionActivity(status: .starting)], focusedSessionID: c.id) { _ in true }
        #expect(busy == b.id)
        let focused = SessionPeek.mostRelevantSession(in: worktree, activities: [:], focusedSessionID: c.id) { _ in true }
        #expect(focused == c.id)
    }

    @Test func fallsBackToALiveTerminalThenTheFirstSession() {
        let worktree = makeWorktree(sessions: [a, b])
        let live = SessionPeek.mostRelevantSession(in: worktree, activities: [:], focusedSessionID: nil) { $0 == b.id }
        #expect(live == b.id)
        let none = SessionPeek.mostRelevantSession(in: worktree, activities: [:], focusedSessionID: nil) { _ in false }
        #expect(none == a.id)
        #expect(SessionPeek.mostRelevantSession(in: makeWorktree(), activities: [:], focusedSessionID: nil) { _ in true } == nil)
    }

    @Test func targetsFollowSidebarRowsAndSkipCollapsedProjects() {
        let single = makeWorktree("single", sessions: [a])
        let multi = makeWorktree("multi", sessions: [b, c])
        let hidden = makeWorktree("hidden", sessions: [makeSession()])
        var open = Project(name: "open", folderURL: URL(fileURLWithPath: "/tmp/open"), worktrees: [single, multi])
        open.isExpanded = true
        var closed = Project(name: "closed", folderURL: URL(fileURLWithPath: "/tmp/closed"), worktrees: [hidden])
        closed.isExpanded = false
        let island = Island(name: "i", symbol: "circle", tint: .blue, projects: [open, closed])

        let targets = SessionPeek.targets(in: island) { $0.sessions.first?.id }
        #expect(targets == [
            .init(worktreeID: single.id, sessionID: a.id),
            .init(worktreeID: multi.id, sessionID: b.id),
            .init(worktreeID: multi.id, sessionID: c.id),
        ])
    }

    @Test func stepClampsAndRecoversFromAMissingTarget() {
        let w1 = UUID(), w2 = UUID()
        let targets = [
            SessionPeek.Target(worktreeID: w1, sessionID: a.id),
            SessionPeek.Target(worktreeID: w2, sessionID: b.id),
            SessionPeek.Target(worktreeID: w2, sessionID: c.id),
        ]
        #expect(SessionPeek.step(from: targets[0], by: 1, in: targets) == targets[1])
        #expect(SessionPeek.step(from: targets[2], by: 1, in: targets) == targets[2])
        #expect(SessionPeek.step(from: targets[0], by: -1, in: targets) == targets[0])
        // The worktree row of a multi-session worktree was hovered, not one of its session rows.
        #expect(SessionPeek.step(from: .init(worktreeID: w2, sessionID: nil), by: -1, in: targets) == targets[0])
        #expect(SessionPeek.step(from: .init(worktreeID: UUID(), sessionID: nil), by: 1, in: targets) == targets[0])
        #expect(SessionPeek.step(from: targets[0], by: 1, in: []) == nil)
    }

    @Test func tailDropsTrailingBlankLinesAndWhitespace() {
        let text = "one  \ntwo\n\nthree\t\n   \n\n"
        #expect(SessionPeek.tail(of: text, lines: 25) == ["one", "two", "", "three"])
        #expect(SessionPeek.tail(of: text, lines: 2) == ["", "three"])
        #expect(SessionPeek.tail(of: "", lines: 5).isEmpty)
    }

    @Test func presentationSurvivesTheOldPopoverLeavingLast() {
        let first = UUID(), second = UUID()
        var presentation = SessionPeek.Presentation()
        presentation.appeared(first)
        presentation.moving(to: second)
        presentation.appeared(second)
        presentation.disappeared(first)
        #expect(presentation.isShowing())
        presentation.disappeared(second)
        #expect(!presentation.isShowing())
    }

    @Test func presentationBridgesTheGapBetweenTwoPopovers() {
        let first = UUID(), second = UUID()
        let start = Date()
        var presentation = SessionPeek.Presentation()
        presentation.appeared(first)
        presentation.moving(to: second, at: start)
        presentation.disappeared(first)
        #expect(presentation.isShowing(at: start.addingTimeInterval(0.1)))
        // A popover that never turns up must not keep the keys forever.
        #expect(!presentation.isShowing(at: start.addingTimeInterval(SessionPeek.Presentation.grace + 0.1)))
        presentation.appeared(second)
        #expect(presentation.isShowing(at: start.addingTimeInterval(10)))
    }
}
