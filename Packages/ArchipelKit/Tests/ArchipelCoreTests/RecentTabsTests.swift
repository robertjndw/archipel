import Foundation
import Testing
@testable import ArchipelCore

struct RecentTabsTests {
    private let a = makeSession("a")
    private let b = makeSession("b")
    private let c = makeSession("c")
    private let d = makeSession("d")
    private let workspace: Workspace

    init() {
        workspace = Workspace(islands: [Island(name: "i", projects: [makeProject("p", sessions: [a, b, c, d])])])
    }

    private func tab(_ session: Session) -> Tab.ID { workspace.tab(showing: session.id)!.id }

    private func isSession(_ session: Session...) -> (Tab) -> Bool {
        { tab in session.contains { tab.content == .session($0.id) } }
    }

    @Test func visitingMovesATabToTheFront() {
        var recent = RecentTabs()
        recent.visit(tab(a))
        recent.visit(tab(b))
        recent.visit(tab(a))
        #expect(recent.ids == [tab(a), tab(b)])
    }

    @Test func dropsDuplicatesAndKeepsTheCapacity() {
        let many = (0..<(RecentTabs.capacity + 5)).map { _ in UUID() }
        var recent = RecentTabs(ids: [many[0]] + many)
        #expect(recent.ids.count == RecentTabs.capacity)
        #expect(recent.ids.first == many[0])
        recent.visit(tab(a))
        #expect(recent.ids.count == RecentTabs.capacity)
        #expect(recent.ids.first == tab(a))
    }

    @Test func candidatesSkipClosedTabsAndAppendVouchedOnes() {
        let recent = RecentTabs(ids: [tab(c), UUID(), tab(a)])
        let ids = recent.candidates(in: workspace, includesUnvisited: isSession(d, a), limit: 10)
        #expect(ids == [tab(c), tab(a), tab(d)])
        #expect(recent.candidates(in: workspace, includesUnvisited: { _ in true }, limit: 2) == [tab(c), tab(a)])
    }

    @Test func aSwitchStartsOnThePreviousTab() {
        let started = TabSwitch(candidates: [tab(a), tab(b), tab(c)], current: tab(a))
        #expect(started?.selectedID == tab(b))
    }

    @Test func aSwitchFromATabNotListedStartsOnTheMostRecentOne() {
        #expect(TabSwitch(candidates: [tab(a), tab(b)], current: nil)?.selectedID == tab(a))
        #expect(TabSwitch(candidates: [tab(a)], current: nil)?.selectedID == tab(a))
    }

    @Test func thereIsNoSwitchWithNowhereToGo() {
        #expect(TabSwitch(candidates: [tab(a)], current: tab(a)) == nil)
        #expect(TabSwitch(candidates: [], current: nil) == nil)
    }

    @Test func advancingWrapsBothWays() {
        var gesture = TabSwitch(candidates: [tab(a), tab(b), tab(c)], current: tab(a))!
        gesture.advance(by: 1)
        #expect(gesture.selectedID == tab(c))
        gesture.advance(by: 1)
        #expect(gesture.selectedID == tab(a))
        gesture.advance(by: -1)
        #expect(gesture.selectedID == tab(c))
        gesture.select(tab(b))
        #expect(gesture.selectedID == tab(b))
    }

    /// Quick taps keep flipping between the same two tabs.
    @Test func quickTapsAlternateBetweenTwoTabs() {
        var recent = RecentTabs(ids: [tab(a), tab(b), tab(c)])
        for expected in [tab(b), tab(a), tab(b)] {
            let ids = recent.candidates(in: workspace, includesUnvisited: { _ in false }, limit: 10)
            let gesture = TabSwitch(candidates: ids, current: ids.first)!
            #expect(gesture.selectedID == expected)
            recent.visit(gesture.selectedID)
        }
    }
}

extension RecentTabsTests {
    @Test func fileTabsCountLikeSessionTabs() {
        var ws = workspace
        let worktree = ws.allWorktrees[0].id
        let file = ws.openTab(.file(URL(fileURLWithPath: "/tmp/p/README.md")), in: worktree, preview: false)!
        var recent = RecentTabs(ids: [tab(a)])
        recent.visit(file)
        #expect(recent.candidates(in: ws, includesUnvisited: { _ in false }, limit: 10) == [file, tab(a)])
        ws.closeTab(id: file)
        #expect(recent.candidates(in: ws, includesUnvisited: { _ in false }, limit: 10) == [tab(a)])
    }
}
