import Foundation
import Testing
@testable import ArchipelCore

struct UndoSnapshotTests {
    let a = makeSession("a"), b = makeSession("b"), c = makeSession("c")
    let file = TabContent.file(URL(fileURLWithPath: "/tmp/p/a.swift"))

    /// A project with sessions a, b, c in the main worktree's only pane, plus a second worktree.
    func fixture() -> (ws: Workspace, project: Project.ID, main: Worktree.ID, other: Worktree.ID) {
        var ws = Workspace()
        let p = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        ws.addProject(p, to: ws.islands[0].id)
        let main = makeWorktree("p", isMain: true), other = makeWorktree("p-feat")
        ws.addWorktree(main, to: p.id)
        ws.addWorktree(other, to: p.id)
        for s in [a, b, c] { ws.addSession(s, to: main.id) }
        return (ws, p.id, main.id, other.id)
    }

    func contents(_ pane: Pane?) -> [TabContent] { pane?.tabs.map(\.content) ?? [] }

    @Test func reopeningASessionTabRestoresRecordAndPosition() throws {
        var (ws, _, m, _) = fixture()
        ws.updateSession(id: b.id) { $0.agentSessionID = "conversation" }
        let tab = try #require(ws.tab(showing: b.id))
        let closed = try #require(ws.closedTab(id: tab.id))
        ws.closeTab(id: tab.id)
        #expect(ws.session(id: b.id) == nil)

        let reopened = ws.reopen(closed)
        #expect(reopened == tab.id)
        #expect(ws.session(id: b.id)?.agentSessionID == "conversation")
        let pane = ws.worktree(id: m)?.panes.first
        #expect(contents(pane) == [.session(a.id), .session(b.id), .session(c.id)])
        #expect(pane?.selectedTabID == tab.id)
        #expect(invariantsHold(ws))
    }

    @Test func reopeningTheLastTabOfASplitRebuildsThePane() throws {
        var (ws, _, m, _) = fixture()
        let tab = try #require(ws.tab(showing: c.id))
        let split = try ws.splitTab(id: tab.id).unwrapped()
        let closed = try #require(ws.closedTab(id: tab.id))
        ws.closeTab(id: tab.id)
        #expect(ws.worktree(id: m)?.panes.count == 1)

        ws.reopen(closed)
        let panes = try #require(ws.worktree(id: m)?.panes)
        #expect(panes.map(\.id).last == split)
        #expect(contents(panes.last) == [.session(c.id)])
        #expect(ws.worktree(id: m)?.focusedPaneID == split)
        #expect(invariantsHold(ws))
    }

    @Test func reopeningAFileThatIsOpenAgainSelectsThatTab() throws {
        var (ws, _, m, _) = fixture()
        let first = try ws.openTab(file, in: m, preview: false).unwrapped()
        let closed = try #require(ws.closedTab(id: first))
        ws.closeTab(id: first)
        let second = try ws.openTab(file, in: m, preview: false).unwrapped()
        ws.selectSession(a.id)

        let reopened = ws.reopen(closed)
        #expect(reopened == second)
        #expect(ws.worktree(id: m)?.panes.flatMap(\.tabs).count { $0.content == file } == 1)
        #expect(ws.worktree(id: m)?.focusedPane?.selectedTab?.id == second)
    }

    @Test func reopenedPreviewIsPinned() throws {
        var (ws, _, m, _) = fixture()
        let id = try ws.openTab(file, in: m, preview: true).unwrapped()
        let closed = try #require(ws.closedTab(id: id))
        ws.closeTab(id: id)
        ws.reopen(closed)
        #expect(ws.tab(id: id)?.isPreview == false)
    }

    @Test func reopeningIntoARemovedWorktreeDoesNothing() throws {
        var (ws, _, _, o) = fixture()
        let d = makeSession("d")
        ws.addSession(d, to: o)
        let tab = try #require(ws.tab(showing: d.id))
        let closed = try #require(ws.closedTab(id: tab.id))
        ws.closeTab(id: tab.id)
        ws.removeWorktree(id: o)

        let reopened = ws.reopen(closed)
        #expect(reopened == nil)
        #expect(ws.session(id: d.id) == nil)
    }

    @Test func placingATabBackUndoesAMoveAcrossPanes() throws {
        var (ws, _, m, _) = fixture()
        let tabA = try #require(ws.tab(showing: a.id)), tabC = try #require(ws.tab(showing: c.id))
        let right = try ws.splitTab(id: tabC.id).unwrapped()
        let before = try #require(ws.placement(ofTab: tabA.id))
        ws.moveTab(id: tabA.id, toPane: right, at: 0)
        let after = try #require(ws.placement(ofTab: tabA.id))

        let undone = ws.place(tab: tabA.id, at: before)
        #expect(undone)
        let panes = try #require(ws.worktree(id: m)?.panes)
        #expect(contents(panes.first) == [.session(a.id), .session(b.id)])
        #expect(contents(panes.last) == [.session(c.id)])

        let redone = ws.place(tab: tabA.id, at: after)
        #expect(redone)
        #expect(contents(ws.pane(id: right)) == [.session(a.id), .session(c.id)])
        #expect(invariantsHold(ws))
    }

    @Test func undoingASplitRemovesThePaneAndRedoRebuildsIt() throws {
        var (ws, _, m, _) = fixture()
        let tab = try #require(ws.tab(showing: b.id))
        let before = try #require(ws.placement(ofTab: tab.id))
        let right = try ws.splitTab(id: tab.id).unwrapped()
        let after = try #require(ws.placement(ofTab: tab.id))

        ws.place(tab: tab.id, at: before)
        #expect(ws.worktree(id: m)?.panes.count == 1)
        #expect(contents(ws.worktree(id: m)?.panes.first) == [.session(a.id), .session(b.id), .session(c.id)])

        ws.place(tab: tab.id, at: after)
        let panes = try #require(ws.worktree(id: m)?.panes)
        #expect(panes.map(\.id) == [before.paneID, right])
        #expect(contents(panes.last) == [.session(b.id)])
        #expect(invariantsHold(ws))
    }

    @Test func movingTwoTabsOutOfAPaneUndoesInReverse() throws {
        var (ws, _, m, _) = fixture()
        let tabB = try #require(ws.tab(showing: b.id)), tabC = try #require(ws.tab(showing: c.id))
        let right = try ws.splitTab(id: tabB.id).unwrapped()
        ws.moveTab(id: tabC.id, toPane: right, at: nil)
        let left = try #require(ws.worktree(id: m)?.panes.first?.id)
        // Right holds b, c. Dragging both left empties and drops it.
        let placeB = try #require(ws.placement(ofTab: tabB.id))
        ws.moveTab(id: tabB.id, toPane: left, at: nil)
        let placeC = try #require(ws.placement(ofTab: tabC.id))
        ws.moveTab(id: tabC.id, toPane: left, at: nil)
        #expect(ws.worktree(id: m)?.panes.count == 1)

        ws.place(tab: tabC.id, at: placeC)
        ws.place(tab: tabB.id, at: placeB)
        #expect(contents(ws.pane(id: right)) == [.session(b.id), .session(c.id)])
        #expect(contents(ws.pane(id: left)) == [.session(a.id)])
        #expect(invariantsHold(ws))
    }

    @Test func placingIgnoresATabThatLeftItsWorktree() throws {
        var (ws, _, _, o) = fixture()
        let tab = try #require(ws.tab(showing: a.id))
        var placement = try #require(ws.placement(ofTab: tab.id))
        placement.worktreeID = o
        let elsewhere = ws.place(tab: tab.id, at: placement)
        let unknown = ws.place(tab: UUID(), at: placement)
        #expect(!elsewhere)
        #expect(!unknown)
    }

    @Test func restoringAWorktreeBringsBackSessionsAtItsIndex() throws {
        var (ws, p, _, o) = fixture()
        let third = makeWorktree("p-third")
        ws.addWorktree(third, to: p)
        let d = makeSession("d")
        ws.addSession(d, to: o)
        let removed = try #require(ws.removal(ofWorktree: o))
        ws.removeWorktree(id: o, dismiss: true)

        let restored = ws.restore(removed)
        #expect(restored)
        let project = try #require(ws.project(id: p))
        #expect(project.worktrees.map(\.id)[1] == o)
        #expect(project.worktrees.count == 3)
        #expect(project.dismissedWorktreePaths.isEmpty)
        #expect(ws.session(id: d.id) != nil)
        #expect(ws.selectedWorktreeID == o)
        let again = ws.restore(removed)
        #expect(!again)
    }
}
