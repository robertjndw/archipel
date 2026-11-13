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
            d.id: SessionActivity(status: .needsAttention(.idle)),
        ]
    }

    @Test func rollUps() {
        let ws = workspace()
        let acts = activities()
        #expect(attentionSummary(of: [a, b, c], activities: acts) == .init(needsAttention: 1, unread: 2))
        #expect(attentionSummary(of: ws.islands[0].projects[0].worktrees[0], activities: acts) == .init(needsAttention: 1, unread: 2))
        #expect(attentionSummary(of: ws.islands[0].projects[0], activities: acts) == .init(needsAttention: 1, unread: 2))
        #expect(attentionSummary(of: ws.islands[0], activities: acts) == .init(needsAttention: 1, unread: 2))
        #expect(attentionSummary(of: ws.islands[1], activities: acts) == .init(needsAttention: 1, unread: 0))
        #expect(attentionSummary(of: ws, activities: acts) == .init(needsAttention: 2, unread: 2))
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
}
