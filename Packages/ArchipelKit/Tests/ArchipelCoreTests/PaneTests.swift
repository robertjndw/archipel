import Foundation
import Testing
@testable import ArchipelCore

struct PaneTests {
    let a = makeSession("a"), b = makeSession("b"), c = makeSession("c")
    let fileA = TabContent.file(URL(fileURLWithPath: "/tmp/a.swift"))
    let fileB = TabContent.file(URL(fileURLWithPath: "/tmp/b.swift"))

    /// A workspace whose main worktree has sessions a, b, c in one pane, plus an empty second worktree.
    func fixture() -> (ws: Workspace, main: Worktree.ID, other: Worktree.ID) {
        var ws = Workspace()
        let p = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        ws.addProject(p, to: ws.islands[0].id)
        let main = makeWorktree("p", isMain: true), other = makeWorktree("p-feat")
        ws.addWorktree(main, to: p.id)
        ws.addWorktree(other, to: p.id)
        for s in [a, b, c] { ws.addSession(s, to: main.id) }
        return (ws, main.id, other.id)
    }

    func wt(_ ws: Workspace, _ id: Worktree.ID) -> Worktree { ws.worktree(id: id)! }
    func titles(_ ws: Workspace, _ pane: Pane) -> [String] {
        pane.tabs.compactMap { tab in
            if case .session(let id) = tab.content { return ws.session(id: id)?.title }
            return nil
        }
    }

    @Test func newWorktreeHasOnePaneWithTabPerSession() {
        let w = makeWorktree(sessions: [a, b])
        #expect(w.panes.count == 1)
        #expect(w.panes[0].tabs.map(\.content) == [.session(a.id), .session(b.id)])
        #expect(w.panes[0].selectedTab?.content == .session(a.id))
        #expect(w.focusedPane?.id == w.panes[0].id)
        #expect(makeWorktree().panes.count == 1)
    }

    @Test func addSessionGoesToFocusedThenExplicitPane() throws {
        var (ws, m, _) = fixture()
        let tab = try #require(ws.tab(showing: c.id))
        let second = try ws.splitTab(id: tab.id).unwrapped()
        let first = try #require(wt(ws, m).panes.first?.id)
        #expect(wt(ws, m).focusedPane?.id == second)

        let d = makeSession("d")
        ws.addSession(d, to: m)
        #expect(ws.pane(id: second)?.tabs.last?.content == .session(d.id))
        #expect(ws.pane(id: second)?.selectedTab?.content == .session(d.id))

        let e = makeSession("e")
        ws.addSession(e, to: m, pane: first)
        #expect(ws.pane(id: first)?.tabs.last?.content == .session(e.id))
        #expect(wt(ws, m).focusedPane?.id == first)

        let f = makeSession("f")
        ws.addSession(f, to: m, pane: .init())
        #expect(ws.pane(id: first)?.tabs.last?.content == .session(f.id))
        #expect(invariantsHold(ws))
    }

    @Test func addSessionKeepsSelectedWorktreeAndIsland() {
        var (ws, m, other) = fixture()
        ws.selectWorktree(other)
        ws.addSession(makeSession(), to: m)
        #expect(ws.selectedWorktreeID == other)
    }

    @Test func openTabReusesEqualContentAnywhere() throws {
        var (ws, m, _) = fixture()
        let id = try ws.openTab(fileA, in: m, preview: true).unwrapped()
        let tab = try #require(ws.tab(showing: c.id))
        let second = try ws.splitTab(id: tab.id).unwrapped()
        #expect(wt(ws, m).focusedPane?.id == second)

        // Preview open keeps the preview flag; a non-preview open pins it.
        #expect(ws.openTab(fileA, in: m, preview: true) == id)
        #expect(ws.tab(id: id)?.isPreview == true)
        #expect(wt(ws, m).focusedPane?.id == ws.pane(containingTab: id)?.id)
        #expect(ws.openTab(fileA, in: m, preview: false) == id)
        #expect(ws.tab(id: id)?.isPreview == false)
        #expect(wt(ws, m).panes.flatMap(\.tabs).count(where: { $0.content == fileA }) == 1)
        #expect(invariantsHold(ws))
    }

    @Test func previewReplacesPreviewInPlace() throws {
        var (ws, m, _) = fixture()
        let first = try ws.openTab(fileA, in: m, preview: true).unwrapped()
        let pinned = try ws.openTab(fileB, in: m, preview: false).unwrapped()
        let diff = TabContent.diff(path: "x.swift", staged: false)
        let replaced = try ws.openTab(diff, in: m, preview: true).unwrapped()

        #expect(replaced == first)
        let tabs = try #require(wt(ws, m).focusedPane?.tabs)
        #expect(tabs.firstIndex { $0.id == first } == 3)
        #expect(tabs.firstIndex { $0.id == pinned } == 4)
        #expect(ws.tab(id: first)?.content == diff)
        #expect(ws.tab(id: first)?.isPreview == true)
        #expect(wt(ws, m).focusedPane?.selectedTab?.id == first)

        // Without a preview tab to reuse, a new one is appended; non-preview never replaces.
        let again = try ws.openTab(fileA, in: m, preview: false).unwrapped()
        #expect(again != first)
        #expect(ws.tab(id: first)?.content == diff)
    }

    @Test func openTabRejectsSessionContentAndUnknownWorktree() {
        var (ws, m, _) = fixture()
        let before = ws
        #expect(ws.openTab(.session(a.id), in: m, preview: false) == nil)
        #expect(ws.openTab(fileA, in: .init(), preview: false) == nil)
        #expect(ws == before)
    }

    @Test func openTabTargetsExplicitPane() throws {
        var (ws, m, _) = fixture()
        let first = wt(ws, m).panes[0].id
        _ = ws.splitTab(id: try #require(ws.tab(showing: c.id)).id)
        let id = try ws.openTab(fileA, in: m, pane: first, preview: false).unwrapped()
        #expect(ws.pane(containingTab: id)?.id == first)
        #expect(wt(ws, m).focusedPane?.id == first)
    }

    @Test func pinTabClearsPreview() throws {
        var (ws, m, _) = fixture()
        let id = try ws.openTab(fileA, in: m, preview: true).unwrapped()
        ws.pinTab(id: id)
        #expect(ws.tab(id: id)?.isPreview == false)
    }

    @Test func closeTabSelectsNextThenPreviousThenNone() throws {
        var (ws, m, _) = fixture()
        let tb = try #require(ws.tab(showing: b.id)), ta = try #require(ws.tab(showing: a.id)), tc = try #require(ws.tab(showing: c.id))
        ws.selectTab(id: tb.id)
        ws.closeTab(id: tb.id)
        #expect(wt(ws, m).panes[0].selectedTab?.id == tc.id)
        ws.closeTab(id: tc.id)
        #expect(wt(ws, m).panes[0].selectedTab?.id == ta.id)
        ws.closeTab(id: ta.id)
        #expect(wt(ws, m).panes.count == 1)
        #expect(wt(ws, m).panes[0].selectedTabID == nil)
        #expect(wt(ws, m).panes[0].tabs.isEmpty)
        #expect(invariantsHold(ws))
    }

    @Test func closingUnselectedTabKeepsSelection() throws {
        var (ws, m, _) = fixture()
        let ta = try #require(ws.tab(showing: a.id)), tc = try #require(ws.tab(showing: c.id))
        #expect(wt(ws, m).panes[0].selectedTab?.id == tc.id)
        ws.closeTab(id: ta.id)
        #expect(wt(ws, m).panes[0].selectedTab?.id == tc.id)
    }

    @Test func closingSessionTabRemovesRecordButFileTabKeepsSessions() throws {
        var (ws, m, _) = fixture()
        let file = try ws.openTab(fileA, in: m, preview: false).unwrapped()
        ws.closeTab(id: file)
        #expect(wt(ws, m).sessions.count == 3)
        ws.closeTab(id: try #require(ws.tab(showing: a.id)).id)
        #expect(ws.session(id: a.id) == nil)
        #expect(wt(ws, m).sessions.map(\.id) == [b.id, c.id])
        ws.closeTab(id: .init())
        #expect(invariantsHold(ws))
    }

    @Test func removeSessionBehavesLikeCloseTab() throws {
        var (ws, m, _) = fixture()
        let tb = try #require(ws.tab(showing: b.id))
        ws.selectTab(id: tb.id)
        ws.removeSession(id: b.id)
        #expect(ws.tab(id: tb.id) == nil)
        #expect(wt(ws, m).panes[0].selectedTab?.content == .session(c.id))
        #expect(invariantsHold(ws))

        // Removing the only session of a split pane drops that pane.
        let second = try ws.splitTab(id: try #require(ws.tab(showing: c.id)).id).unwrapped()
        ws.removeSession(id: c.id)
        #expect(ws.pane(id: second) == nil)
        #expect(wt(ws, m).panes.count == 1)
        #expect(invariantsHold(ws))
    }

    @Test func closingLastTabOfPaneRemovesPaneAndHandsOverFocus() throws {
        var (ws, m, _) = fixture()
        // Panes: [a, b] [c] after one split, then [a] [b] [c].
        let p1 = wt(ws, m).panes[0].id
        let p2 = try ws.splitTab(id: try #require(ws.tab(showing: c.id)).id).unwrapped()
        let p3 = try ws.splitTab(id: try #require(ws.tab(showing: b.id)).id).unwrapped()
        #expect(wt(ws, m).panes.map(\.id) == [p1, p3, p2])

        ws.closeTab(id: try #require(ws.tab(showing: b.id)).id)
        #expect(wt(ws, m).panes.map(\.id) == [p1, p2])
        #expect(wt(ws, m).focusedPane?.id == p2)

        ws.focusPane(id: p2)
        ws.closeTab(id: try #require(ws.tab(showing: c.id)).id)
        #expect(wt(ws, m).panes.map(\.id) == [p1])
        #expect(wt(ws, m).focusedPane?.id == p1)
    }

    @Test func closingUnfocusedEmptyPaneKeepsFocus() throws {
        var (ws, m, _) = fixture()
        let p1 = wt(ws, m).panes[0].id
        let p2 = try ws.splitTab(id: try #require(ws.tab(showing: c.id)).id).unwrapped()
        ws.focusPane(id: p1)
        ws.closeTab(id: try #require(ws.tab(showing: c.id)).id)
        #expect(ws.pane(id: p2) == nil)
        #expect(wt(ws, m).focusedPane?.id == p1)
    }

    @Test func moveTabReordersWithinPane() throws {
        var (ws, m, _) = fixture()
        let pane = wt(ws, m).panes[0].id
        let ta = try #require(ws.tab(showing: a.id)).id, tc = try #require(ws.tab(showing: c.id)).id
        ws.moveTab(id: tc, toPane: pane, at: 0)
        #expect(titles(ws, wt(ws, m).panes[0]) == ["c", "a", "b"])
        ws.moveTab(id: tc, toPane: pane, at: 99)
        #expect(titles(ws, wt(ws, m).panes[0]) == ["a", "b", "c"])
        ws.moveTab(id: ta, toPane: pane, at: -4)
        #expect(titles(ws, wt(ws, m).panes[0]) == ["a", "b", "c"])
        ws.moveTab(id: ta, toPane: pane)
        #expect(titles(ws, wt(ws, m).panes[0]) == ["b", "c", "a"])
        #expect(wt(ws, m).panes[0].selectedTab?.id == ta)
    }

    @Test func moveTabAcrossPanes() throws {
        var (ws, m, _) = fixture()
        let p1 = wt(ws, m).panes[0].id
        let p2 = try ws.splitTab(id: try #require(ws.tab(showing: c.id)).id).unwrapped()
        let tb = try #require(ws.tab(showing: b.id)).id
        ws.selectTab(id: tb)

        ws.moveTab(id: tb, toPane: p2, at: 0)
        #expect(titles(ws, ws.pane(id: p1)!) == ["a"])
        #expect(titles(ws, ws.pane(id: p2)!) == ["b", "c"])
        #expect(ws.pane(id: p2)?.selectedTab?.id == tb)
        #expect(ws.pane(id: p1)?.selectedTab?.content == .session(a.id))
        #expect(wt(ws, m).focusedPane?.id == p2)

        ws.moveTab(id: tb, toPane: p1, at: 50)
        #expect(titles(ws, ws.pane(id: p1)!) == ["a", "b"])
        #expect(ws.pane(id: p2)?.selectedTab?.content == .session(c.id))
        #expect(wt(ws, m).focusedPane?.id == p1)
        #expect(invariantsHold(ws))
    }

    @Test func moveTabRemovesEmptiedSourcePaneButNeverTheLast() throws {
        var (ws, m, _) = fixture()
        let p1 = wt(ws, m).panes[0].id
        let p2 = try ws.splitTab(id: try #require(ws.tab(showing: c.id)).id).unwrapped()
        let tc = try #require(ws.tab(showing: c.id)).id

        ws.moveTab(id: tc, toPane: p1)
        #expect(ws.pane(id: p2) == nil)
        #expect(wt(ws, m).panes.map(\.id) == [p1])
        #expect(wt(ws, m).focusedPane?.id == p1)

        // Moving within a lone pane never removes it.
        ws.moveTab(id: tc, toPane: p1, at: 0)
        #expect(wt(ws, m).panes.count == 1)
        #expect(invariantsHold(ws))
    }

    @Test func moveTabAcrossWorktreesIsNoOp() throws {
        var (ws, m, other) = fixture()
        let foreign = wt(ws, other).panes[0].id
        let before = ws
        ws.moveTab(id: try #require(ws.tab(showing: a.id)).id, toPane: foreign)
        ws.moveTab(id: try #require(ws.tab(showing: a.id)).id, toPane: .init())
        ws.moveTab(id: .init(), toPane: wt(ws, m).panes[0].id)
        #expect(ws == before)
    }

    @Test func splitTabInsertsNewPaneAfterCurrent() throws {
        var (ws, m, _) = fixture()
        let p1 = wt(ws, m).panes[0].id
        let tb = try #require(ws.tab(showing: b.id)).id
        let p2 = try ws.splitTab(id: tb).unwrapped()
        #expect(wt(ws, m).panes.map(\.id) == [p1, p2])
        #expect(ws.pane(id: p2)?.tabs.map(\.id) == [tb])
        #expect(ws.pane(id: p2)?.selectedTabID == tb)
        #expect(wt(ws, m).focusedPane?.id == p2)
        #expect(titles(ws, ws.pane(id: p1)!) == ["a", "c"])

        // Splitting from the first pane of two lands between them.
        let ta = try #require(ws.tab(showing: a.id)).id
        let p3 = try ws.splitTab(id: ta).unwrapped()
        #expect(wt(ws, m).panes.map(\.id) == [p1, p3, p2])
        #expect(invariantsHold(ws))
    }

    @Test func splitTabOfOnlyTabChangesNothing() throws {
        var (ws, m, other) = fixture()
        ws.addSession(makeSession("solo"), to: other)
        let only = try #require(wt(ws, other).panes[0].tabs.first).id
        let before = ws
        #expect(ws.splitTab(id: only) == nil)
        #expect(ws.splitTab(id: .init()) == nil)
        #expect(ws == before)
        _ = m
    }

    @Test func selectTabReachesWorktreeAndIsland() throws {
        var (ws, m, other) = fixture()
        let home = ws.islands[0].id
        let p2 = try ws.splitTab(id: try #require(ws.tab(showing: c.id)).id).unwrapped()
        let ta = try #require(ws.tab(showing: a.id)).id
        ws.selectWorktree(other)
        ws.addIsland(name: "Work")

        ws.selectTab(id: ta)
        #expect(ws.selectedIslandID == home)
        #expect(ws.selectedWorktreeID == m)
        #expect(wt(ws, m).focusedPane?.id != p2)
        #expect(wt(ws, m).focusedPane?.selectedTab?.id == ta)
    }

    @Test func selectSessionFocusesItsPane() throws {
        var (ws, m, other) = fixture()
        let home = ws.islands[0].id
        let p1 = wt(ws, m).panes[0].id
        _ = ws.splitTab(id: try #require(ws.tab(showing: c.id)).id)
        ws.selectWorktree(other)
        ws.addIsland(name: "Work")

        ws.selectSession(a.id)
        #expect(ws.selectedIslandID == home)
        #expect(ws.selectedWorktreeID == m)
        #expect(wt(ws, m).focusedPane?.id == p1)
        #expect(ws.focusedSessionID(in: m) == a.id)
        ws.selectSession(.init())
        #expect(ws.focusedSessionID(in: m) == a.id)
    }

    @Test func visibleAndFocusedSessionIDs() throws {
        var (ws, m, other) = fixture()
        #expect(ws.visibleSessionIDs(in: m) == [c.id])
        _ = ws.splitTab(id: try #require(ws.tab(showing: c.id)).id)
        #expect(ws.visibleSessionIDs(in: m) == [b.id, c.id])
        #expect(ws.focusedSessionID(in: m) == c.id)

        // A file tab selected in a pane hides that pane's session from both lists.
        _ = ws.openTab(fileA, in: m, preview: false)
        #expect(ws.visibleSessionIDs(in: m) == [b.id])
        #expect(ws.focusedSessionID(in: m) == nil)

        #expect(ws.visibleSessionIDs(in: other).isEmpty)
        #expect(ws.visibleSessionIDs(in: .init()).isEmpty)
        #expect(ws.focusedSessionID(in: .init()) == nil)
    }

    @Test func lookups() throws {
        let (ws, m, other) = fixture()
        let tab = try #require(ws.tab(showing: b.id))
        let pane = try #require(ws.pane(containingTab: tab.id))
        #expect(ws.pane(id: pane.id) == pane)
        #expect(ws.tab(id: tab.id) == tab)
        #expect(ws.worktree(containingTab: tab.id)?.id == m)
        #expect(ws.worktree(containingPane: pane.id)?.id == m)
        #expect(ws.worktree(containingPane: wt(ws, other).panes[0].id)?.id == other)
        #expect(ws.tab(id: .init()) == nil && ws.pane(id: .init()) == nil && ws.pane(containingTab: .init()) == nil)
        #expect(ws.worktree(containingTab: .init()) == nil && ws.worktree(containingPane: .init()) == nil)
    }

    @Test func updateWorktreeRepairsBrokenInvariants() {
        var (ws, m, _) = fixture()
        let extra = makeSession("extra")
        ws.updateWorktree(id: m) {
            $0.sessions.append(extra)
            $0.sessions.removeAll { $0.id == a.id }
            $0.panes = []
        }
        #expect(invariantsHold(ws))
        #expect(wt(ws, m).panes[0].tabs.map(\.content) == [.session(b.id), .session(c.id), .session(extra.id)])
    }

    @Test func fileTabsSurviveRepair() throws {
        var (ws, m, _) = fixture()
        let id = try ws.openTab(fileA, in: m, preview: true).unwrapped()
        ws.updateWorktree(id: m) { $0.branch = "x" }
        #expect(ws.tab(id: id)?.content == fileA)
        #expect(ws.tab(id: id)?.isPreview == true)
    }

    // MARK: Decoding

    func decode(_ json: String) throws -> Workspace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Workspace.self, from: Data(json.utf8))
    }

    @Test func versionTwoWorktreeWithoutPanesGetsOnePane() throws {
        let island = "0F0A5E0C-1111-4111-8111-000000000001"
        let wtID = "0F0A5E0C-1111-4111-8111-000000000002"
        let s1 = "0F0A5E0C-1111-4111-8111-000000000003"
        let s2 = "0F0A5E0C-1111-4111-8111-000000000004"
        let ws = try decode("""
        {
          "schemaVersion": 2,
          "selectedIslandID": "\(island)",
          "selectedWorktreeIDByIsland": ["\(island)", "\(wtID)"],
          "selectedSessionIDByWorktree": ["\(wtID)", "\(s2)"],
          "islands": [{
            "id": "\(island)", "name": "Personal", "symbol": "house", "tint": "blue",
            "projects": [{
              "id": "0F0A5E0C-1111-4111-8111-000000000005", "name": "p", "folderURL": "file:///tmp/p/",
              "worktrees": [{
                "id": "\(wtID)", "path": "file:///tmp/p/", "isMain": true,
                "sessions": [
                  {"id": "\(s1)", "title": "one", "agent": "claude", "createdAt": "2026-11-13T17:38:55Z"},
                  {"id": "\(s2)", "title": "two", "agent": "shell", "createdAt": "2026-11-13T17:39:55Z"}
                ]
              }]
            }]
          }]
        }
        """)
        let worktree = try #require(ws.worktree(id: UUID(uuidString: wtID)!))
        #expect(worktree.panes.count == 1)
        #expect(worktree.panes[0].tabs.map(\.content) == [.session(UUID(uuidString: s1)!), .session(UUID(uuidString: s2)!)])
        #expect(worktree.panes[0].selectedTab?.content == .session(UUID(uuidString: s2)!))
        #expect(worktree.focusedPane?.id == worktree.panes[0].id)
        #expect(invariantsHold(ws))
    }

    @Test func decodingRepairsInconsistentPanes() throws {
        let id = UUID(), s1 = UUID(), s2 = UUID(), ghost = UUID()
        let paneID = UUID(), emptyID = UUID(), tabID = UUID()
        var w = Worktree(id: id, path: URL(fileURLWithPath: "/tmp/p"), sessions: [])
        w.sessions = [makeSession("one"), makeSession("two")]
        w.sessions[0].id = s1
        w.sessions[1].id = s2
        w.panes = [
            Pane(id: paneID, tabs: [Tab(id: tabID, content: .session(s1)), Tab(content: .session(ghost)), Tab(content: .session(s1))],
                 selectedTabID: UUID()),
            Pane(id: emptyID),
        ]
        w.focusedPaneID = UUID()
        let data = try JSONEncoder().encode(w)
        // Encoding the broken value verbatim is the point, so bypass the repair done by Workspace.
        let fixed = try JSONDecoder().decode(Worktree.self, from: data)

        #expect(fixed.panes.map(\.id) == [paneID])
        #expect(fixed.panes[0].tabs.map(\.content) == [.session(s1), .session(s2)])
        #expect(fixed.panes[0].tabs[0].id == tabID)
        #expect(fixed.panes[0].selectedTabID == tabID)
        #expect(fixed.focusedPaneID == paneID)
    }

    @Test func decodingKeepsFileAndDiffTabs() throws {
        var w = makeWorktree(sessions: [a])
        w.panes[0].tabs.append(Tab(content: fileA, isPreview: true))
        w.panes[0].tabs.append(Tab(content: .diff(path: "src/x.swift", staged: true)))
        let back = try JSONDecoder().decode(Worktree.self, from: JSONEncoder().encode(w))
        #expect(back == w)
    }
}
