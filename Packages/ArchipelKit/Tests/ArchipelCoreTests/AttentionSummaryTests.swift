import Testing
@testable import ArchipelCore

struct AttentionTests {
    let a = makeSession("a"), b = makeSession("b"), c = makeSession("c"), d = makeSession("d")

    func workspace() -> Workspace {
        var ws = Workspace()
        let second = ws.addIsland(name: "Work")
        let first = ws.islands[0].id
        let p1 = makeProject("p1", sessions: [a, b])
        let p2 = makeProject("p2", sessions: [c])
        let p3 = makeProject("p3", sessions: [d])
        ws.addProject(p1, to: first)
        ws.addProject(p2, to: first)
        ws.addProject(p3, to: second)
        return ws
    }

    func activities() -> [Session.ID: SessionActivity] {
        [
            a.id: SessionActivity(status: .needsAttention(.permission), unread: true),
            b.id: SessionActivity(status: .finished, unread: true),
            c.id: SessionActivity(status: .working),
            d.id: SessionActivity(status: .needsAttention(.question)),
        ]
    }

    @Test func rollUps() {
        let ws = workspace()
        let acts = activities()
        #expect(attentionSummary(of: [a, b, c], activities: acts) == .init(needsAttention: 1, unread: 2, working: 1))
        #expect(attentionSummary(of: ws.islands[0].projects[0].worktrees[0], activities: acts) == .init(needsAttention: 1, unread: 2))
        #expect(attentionSummary(of: ws.islands[0].projects[0], activities: acts) == .init(needsAttention: 1, unread: 2))
        #expect(attentionSummary(of: ws.islands[0], activities: acts) == .init(needsAttention: 1, unread: 2, working: 1))
        #expect(attentionSummary(of: ws.islands[1], activities: acts) == .init(needsAttention: 1, unread: 0))
        #expect(attentionSummary(of: ws, activities: acts) == .init(needsAttention: 2, unread: 2, working: 1))
        #expect(attentionSummary(of: ws, activities: [:]) == .zero)
    }

    @Test func nextCyclesThroughIslandsInOrder() {
        let ws = workspace()
        let acts = activities()
        #expect(nextSessionNeedingAttention(after: nil, in: ws, activities: acts) == a.id)
        #expect(nextSessionNeedingAttention(after: a.id, in: ws, activities: acts) == d.id)
        #expect(nextSessionNeedingAttention(after: d.id, in: ws, activities: acts) == a.id)
    }

    @Test func nextPrefersAttentionOverUnreadFinished() {
        let ws = workspace()
        var acts = activities()
        acts[a.id] = nil
        #expect(nextSessionNeedingAttention(after: nil, in: ws, activities: acts) == d.id)
    }

    @Test func nextFallsBackToUnreadFinished() {
        let ws = workspace()
        var acts = activities()
        acts[a.id] = nil
        acts[d.id] = nil
        #expect(nextSessionNeedingAttention(after: nil, in: ws, activities: acts) == b.id)
        acts[b.id]?.markViewed()
        #expect(nextSessionNeedingAttention(after: nil, in: ws, activities: acts) == nil)
    }

    @Test func nextWithUnknownCurrentStartsAtTop() {
        #expect(nextSessionNeedingAttention(after: .init(), in: workspace(), activities: activities()) == a.id)
    }

    @Test func dominantSignalAndDescription() {
        #expect(AttentionSummary.zero.dominant == nil)
        #expect(AttentionSummary.zero.accessibilityDescription.isEmpty)
        #expect(AttentionSummary(working: 2).dominant == .working)
        #expect(AttentionSummary(unread: 1, working: 2).dominant == .unread)
        let all = AttentionSummary(needsAttention: 3, unread: 1, working: 1)
        #expect(all.dominant == .needsAttention(3))
        #expect(all.accessibilityDescription == "3 waiting for you, 1 unread, 1 agent working")
    }

    @Test func startingCountsAsWorking() {
        let acts = [a.id: SessionActivity(status: .starting), b.id: SessionActivity(status: .finished)]
        #expect(attentionSummary(of: [a, b], activities: acts) == .init(working: 1))
    }

    @Test func attentionWorktreesSpanIslandsAndMatchTheJump() {
        let ws = workspace()
        var acts = activities()
        let first = ws.islands[0].projects[0].worktrees[0].id
        let other = ws.islands[1].projects[0].worktrees[0].id
        #expect(worktreesNeedingAttention(in: ws, activities: acts) == [first, other])

        // The jump only lands on sessions that this filter lists too.
        acts[a.id] = nil
        acts[d.id] = nil
        #expect(worktreesNeedingAttention(in: ws, activities: acts) == [first])
        #expect(ws.worktree(containing: nextSessionNeedingAttention(after: nil, in: ws, activities: acts)!)?.id == first)

        acts[b.id]?.markViewed()
        #expect(worktreesNeedingAttention(in: ws, activities: acts).isEmpty)
        #expect(nextSessionNeedingAttention(after: nil, in: ws, activities: acts) == nil)
    }

    @Test func workingAndFreshSessionsDoNotNeedMe() {
        #expect(!SessionActivity(status: .working, unread: true).needsMe)
        #expect(!SessionActivity(status: .finished).needsMe)
        #expect(SessionActivity(status: .finished, unread: true).needsMe)
        #expect(SessionActivity(status: .needsAttention(.question)).needsMe)
    }

    @Test func finishedTurnWithSubagentsRunningCountsAsWorking() {
        var activity = SessionActivity(status: .working)
        activity.apply(.subagentStarted(id: "x"), isBeingViewed: false)
        activity.apply(.turnFinished(message: nil, backgroundTasks: nil), isBeingViewed: false)
        let summary = attentionSummary(of: [a], activities: [a.id: activity])
        #expect(summary == .init(working: 1))
        #expect(summary.dominant == .working)
    }
}
