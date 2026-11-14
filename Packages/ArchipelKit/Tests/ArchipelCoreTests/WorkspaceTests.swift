import Foundation
import Testing
@testable import ArchipelCore

struct WorkspaceTests {
    @Test func newWorkspaceHasPersonalIsland() {
        let ws = Workspace()
        #expect(ws.islands.map(\.name) == ["Personal"])
        #expect(ws.selectedIslandID == ws.islands[0].id)
        #expect(ws.schemaVersion == Workspace.currentSchemaVersion)
    }

    @Test func lastIslandCannotBeRemoved() {
        var ws = Workspace()
        let removed = ws.removeIsland(id: ws.islands[0].id)
        #expect(!removed)
        #expect(ws.islands.count == 1)
    }

    @Test func removingSelectedIslandSelectsNeighbour() {
        var ws = Workspace()
        let b = ws.addIsland(name: "B")
        let c = ws.addIsland(name: "C")
        ws.selectIsland(b)
        let first = ws.removeIsland(id: b)
        #expect(first)
        #expect(ws.selectedIslandID == c)
        let second = ws.removeIsland(id: c)
        #expect(second)

        #expect(ws.selectedIslandID == ws.islands[0].id)
    }

    @Test func removingOtherIslandKeepsSelection() {
        var ws = Workspace()
        let b = ws.addIsland(name: "B")
        ws.selectIsland(ws.islands[0].id)
        ws.removeIsland(id: b)
        #expect(ws.selectedIslandID == ws.islands[0].id)
    }

    @Test func renameAndMoveIslands() {
        var ws = Workspace()
        let b = ws.addIsland(name: "B")
        let c = ws.addIsland(name: "C")
        ws.renameIsland(id: b, to: "Bee")
        ws.moveIsland(id: c, to: 0)
        #expect(ws.islands.map(\.name) == ["C", "Personal", "Bee"])
        ws.moveIsland(id: c, to: 99)
        #expect(ws.islands.map(\.name) == ["Personal", "Bee", "C"])
    }

    @Test func projectsMoveWithinAndAcrossIslands() {
        var ws = Workspace()
        let home = ws.islands[0].id
        let work = ws.addIsland(name: "Work")
        let p1 = makeProject("p1"), p2 = makeProject("p2")
        ws.addProject(p1, to: home)
        ws.addProject(p2, to: home)

        ws.moveProject(id: p2.id, to: home, at: 0)
        #expect(ws.islands[0].projects.map(\.name) == ["p2", "p1"])

        ws.moveProject(id: p1.id, to: work)
        #expect(ws.island(id: home)?.projects.map(\.name) == ["p2"])
        #expect(ws.island(id: work)?.projects.map(\.name) == ["p1"])
        #expect(ws.island(containingProject: p1.id)?.id == work)
    }

    /// One island with a project holding a main worktree and a second worktree.
    func fixture() -> (ws: Workspace, project: Project, main: Worktree, other: Worktree) {
        var ws = Workspace()
        let p = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        ws.addProject(p, to: ws.islands[0].id)
        let main = makeWorktree("p", isMain: true), other = makeWorktree("p-feat", branch: "feat")
        ws.addWorktree(main, to: p.id)
        ws.addWorktree(other, to: p.id)
        return (ws, p, main, other)
    }

    @Test func displayTitleRules() {
        var s = Session(title: "Claude Code", agent: .claude)
        #expect(s.displayTitle == "Claude Code")
        s.agentTitle = "Fix login"
        #expect(s.displayTitle == "Fix login")
        s.agentTitle = ""
        #expect(s.displayTitle == "Claude Code")
        s.agentTitle = "Fix login"
        s.title = "Mine"
        s.hasCustomTitle = true
        #expect(s.displayTitle == "Mine")
    }

    @Test func worktreeDisplayName() {
        #expect(makeWorktree("folder", branch: "main").displayName == "main")
        #expect(makeWorktree("folder").displayName == "folder")
    }

    @Test func addWorktreeSelectsAndRejectsDuplicatePath() {
        var (ws, p, main, other) = fixture()
        #expect(ws.selectedWorktreeID == other.id)
        #expect(ws.worktree(id: main.id) == main)
        #expect(ws.project(containingWorktree: other.id)?.id == p.id)
        #expect(ws.island(containingWorktree: other.id)?.id == ws.islands[0].id)

        let before = ws
        let dup = Worktree(path: URL(fileURLWithPath: "/tmp/other/../p-feat"))
        let dupAdded = ws.addWorktree(dup, to: p.id)
        let orphanAdded = ws.addWorktree(makeWorktree("x"), to: .init())
        #expect(!dupAdded)
        #expect(!orphanAdded)
        #expect(ws == before)
    }

    @Test func removeWithDismissRecordsPathOnly() {
        var (ws, p, _, other) = fixture()
        let key = Project.worktreeKey(other.path)
        ws.removeWorktree(id: other.id)
        #expect(ws.project(id: p.id)?.dismissedWorktreePaths == [])

        ws.addWorktree(other, to: p.id)
        ws.removeWorktree(id: other.id, dismiss: true)
        #expect(ws.project(id: p.id)?.dismissedWorktreePaths == [key])

        ws.addWorktree(other, to: p.id)
        #expect(ws.project(id: p.id)?.dismissedWorktreePaths == [])
    }

    @Test func mainWorktreeIsNeverDismissed() {
        var (ws, p, main, _) = fixture()
        ws.removeWorktree(id: main.id, dismiss: true)
        #expect(ws.project(id: p.id)?.worktrees.contains { $0.id == main.id } == true)
        #expect(ws.project(id: p.id)?.dismissedWorktreePaths == [])
    }

    @Test func dismissAndRestoreWorktrees() {
        var (ws, p, _, _) = fixture()
        ws.dismissWorktree(path: URL(fileURLWithPath: "/tmp/a/"), in: p.id)
        ws.dismissWorktree(path: URL(fileURLWithPath: "/tmp/b"), in: p.id)
        #expect(ws.project(id: p.id)?.dismissedWorktreePaths == ["/tmp/a", "/tmp/b"])

        ws.restoreDismissedWorktrees(in: p.id)
        #expect(ws.project(id: p.id)?.dismissedWorktreePaths == [])
    }

    @Test func worktreeKeyIgnoresTrailingSlash() {
        #expect(Project.worktreeKey(URL(fileURLWithPath: "/a/b/")) == Project.worktreeKey(URL(fileURLWithPath: "/a/b")))
        #expect(Project.worktreeKey(URL(fileURLWithPath: "/a/b/")) == "/a/b")
        #expect(Project.worktreeKey(URL(fileURLWithPath: "/a/c/../b")) == "/a/b")
    }

    @Test func mainWorktreeCannotBeRemoved() {
        var (ws, p, main, other) = fixture()
        ws.removeWorktree(id: main.id)
        #expect(ws.project(id: p.id)?.worktrees.count == 2)

        #expect(ws.selectedWorktreeID == other.id)
        ws.removeWorktree(id: other.id)
        #expect(ws.project(id: p.id)?.worktrees.map(\.id) == [main.id])
        #expect(ws.selectedWorktreeID == main.id)
    }

    @Test func removingWorktreeDropsItsSessions() {
        var (ws, _, _, other) = fixture()
        let s = makeSession()
        ws.addSession(s, to: other.id)
        ws.removeWorktree(id: other.id)
        #expect(ws.session(id: s.id) == nil)
        #expect(ws.tab(showing: s.id) == nil)
    }

    @Test func sessionLookups() {
        var (ws, p, main, _) = fixture()
        let s1 = makeSession("s1"), s2 = makeSession("s2")
        ws.addSession(s1, to: main.id)
        ws.addSession(s2, to: main.id)

        #expect(ws.session(id: s1.id) == s1)
        #expect(ws.worktree(containing: s2.id)?.id == main.id)
        #expect(ws.project(containing: s2.id)?.id == p.id)
        #expect(ws.island(containing: s2.id)?.id == ws.islands[0].id)
        #expect(ws.session(id: .init()) == nil)
        #expect(ws.allSessions.map(\.id) == [s1.id, s2.id])
        let added = ws.addSession(makeSession(), to: .init())
        #expect(!added)
    }

    @Test func selectWorktreeSwitchesIsland() {
        var (ws, _, main, _) = fixture()
        let work = ws.addIsland(name: "Work")
        ws.selectWorktree(main.id)
        #expect(ws.selectedIslandID == ws.islands[0].id)
        #expect(ws.selectedWorktreeIDByIsland[work] == nil)
    }

    @Test func removingProjectClearsSelections() {
        var (ws, p, main, _) = fixture()
        let s = makeSession()
        ws.addSession(s, to: main.id)
        ws.removeProject(id: p.id)
        #expect(ws.selectedWorktreeIDByIsland.isEmpty)
        #expect(ws.session(id: s.id) == nil)
    }

    @Test func removingIslandClearsItsSelections() {
        var (ws, _, main, _) = fixture()
        ws.addSession(makeSession(), to: main.id)
        ws.addIsland(name: "Other")
        ws.removeIsland(id: ws.islands[0].id)
        #expect(ws.selectedWorktreeIDByIsland.isEmpty)
    }

    @Test func movingProjectAcrossIslandsDropsStaleSelection() {
        var (ws, p, main, _) = fixture()
        let home = ws.islands[0].id
        let work = ws.addIsland(name: "Work")
        ws.addSession(makeSession(), to: main.id)
        ws.selectWorktree(main.id)
        ws.moveProject(id: p.id, to: work)

        #expect(ws.island(containingProject: p.id)?.id == work)
        #expect(ws.selectedWorktreeIDByIsland[home] == nil)
        #expect(ws.worktree(id: main.id)?.sessions.count == 1)
    }

    @Test func missingOptionalKeysDecodeWithDefaults() throws {
        let id = UUID().uuidString
        let json = """
        {"id": "\(id)", "name": "p", "folderURL": "file:///tmp/p", "worktrees": [
          {"id": "\(id)", "path": "file:///tmp/p", "sessions": [
            {"id": "\(id)", "title": "Claude Code", "agent": "claude", "createdAt": "2023-11-14T22:13:20Z"}
          ]}
        ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(json.utf8))
        #expect(project.isExpanded)
        #expect(!project.worktrees[0].isMain)
        #expect(project.worktrees[0].branch == nil)
        #expect(!project.worktrees[0].sessions[0].hasCustomTitle)
        #expect(project.worktrees[0].sessions[0].agentTitle == nil)
    }

    @Test func agentKindEncodesAsPlainString() throws {
        let data = try JSONEncoder().encode([AgentKind.codex])
        #expect(String(decoding: data, as: UTF8.self) == "[\"codex\"]")
        #expect(try JSONDecoder().decode([AgentKind].self, from: data) == [.codex])
    }
}
