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

    @Test func newSessionTitlesTakeTheFirstFreeNumber() {
        func session(_ title: String, custom: Bool = false) -> Session {
            Session(title: title, hasCustomTitle: custom, agent: .claude)
        }
        #expect(Session.numberedTitle("Claude Code", among: []) == "Claude Code")
        #expect(Session.numberedTitle("Claude Code", among: [session("Claude Code")]) == "Claude Code 2")
        // The second tab was closed: its number is free again, and the third keeps its own.
        #expect(Session.numberedTitle("Claude Code", among: [session("Claude Code"), session("Claude Code 3")]) == "Claude Code 2")
        // The first was closed.
        #expect(Session.numberedTitle("Claude Code", among: [session("Claude Code 2")]) == "Claude Code")
        // Numbered per agent: a preset's tab holds its number too.
        #expect(Session.numberedTitle("Claude Code (Opus)", among: [session("Claude Code"), session("Claude Code (Plan) 2")]) == "Claude Code (Opus) 3")
        #expect(Session.numberedTitle("Claude Code", among: [session("Fix login 2", custom: true)]) == "Claude Code")
        #expect(Session.numberedTitle("Claude Code", among: [session("Release", custom: true)]) == "Claude Code")
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

    @Test func removingTheSelectedProjectSelectsItsNeighbour() {
        var (ws, p, main, _) = fixture()
        let home = ws.islands[0].id
        let q = makeProject("q"), r = makeProject("r")
        ws.addProject(q, to: home)
        ws.addProject(r, to: home)

        ws.selectWorktree(main.id)
        ws.removeProject(id: p.id)
        // q took p's place.
        #expect(ws.selectedWorktreeIDByIsland[home] == q.worktrees[0].id)

        ws.selectWorktree(r.worktrees[0].id)
        ws.removeProject(id: r.id)
        // r was last, so the one before it is shown.
        #expect(ws.selectedWorktreeIDByIsland[home] == q.worktrees[0].id)

        ws.removeProject(id: q.id)
        #expect(ws.selectedWorktreeIDByIsland[home] == nil)
    }

    @Test func removingAProjectInTheMiddleSelectsTheOneAfterIt() {
        var (ws, p, main, _) = fixture()
        let home = ws.islands[0].id
        let q = makeProject("q"), r = makeProject("r")
        ws.addProject(q, to: home)
        ws.addProject(r, to: home)

        ws.selectWorktree(q.worktrees[0].id)
        ws.removeProject(id: q.id)
        #expect(ws.selectedWorktreeIDByIsland[home] == r.worktrees[0].id)

        // p lists a linked worktree after its main checkout; the main checkout is what is shown.
        ws.selectWorktree(r.worktrees[0].id)
        ws.removeProject(id: r.id)
        #expect(ws.selectedWorktreeIDByIsland[home] == main.id)
        #expect(ws.project(id: p.id)?.worktrees.last?.id != main.id)
    }

    @Test func removingAProjectBeforeTheSelectedOneKeepsTheSelection() {
        var (ws, p, _, _) = fixture()
        let home = ws.islands[0].id
        let q = makeProject("q"), r = makeProject("r")
        ws.addProject(q, to: home)
        ws.addProject(r, to: home)
        ws.selectWorktree(r.worktrees[0].id)
        ws.removeProject(id: p.id)
        #expect(ws.selectedWorktreeIDByIsland[home] == r.worktrees[0].id)
    }

    @Test func removingAnotherProjectKeepsTheSelection() {
        var (ws, _, main, _) = fixture()
        let home = ws.islands[0].id
        let q = makeProject("q")
        ws.addProject(q, to: home)
        ws.selectWorktree(main.id)
        ws.removeProject(id: q.id)
        #expect(ws.selectedWorktreeIDByIsland[home] == main.id)
    }

    @Test func islandsAndProjectsMoveByOneStoppingAtTheEnds() {
        var ws = Workspace()
        let home = ws.islands[0].id
        let b = ws.addIsland(name: "B")
        ws.moveIsland(id: b, by: -1)
        #expect(ws.islands.map(\.name) == ["B", "Personal"])
        ws.moveIsland(id: b, by: -1)
        #expect(ws.islands.map(\.name) == ["B", "Personal"])
        ws.moveIsland(id: b, by: 1)
        #expect(ws.islands.map(\.name) == ["Personal", "B"])
        ws.moveIsland(id: b, by: 1)
        #expect(ws.islands.map(\.name) == ["Personal", "B"])

        let c = ws.addIsland(name: "C")
        ws.moveIsland(id: c, before: home)
        #expect(ws.islands.map(\.name) == ["C", "Personal", "B"])
        ws.moveIsland(id: c, before: nil)
        #expect(ws.islands.map(\.name) == ["Personal", "B", "C"])
        ws.moveIsland(id: home, before: c)
        #expect(ws.islands.map(\.name) == ["B", "Personal", "C"])
        ws.moveIsland(id: c, before: c)
        #expect(ws.islands.map(\.name) == ["B", "Personal", "C"])
        ws.moveIsland(id: home, before: home)
        #expect(ws.islands.map(\.name) == ["B", "Personal", "C"])
        ws.moveIsland(id: home, before: nil)
        ws.moveIsland(id: b, before: nil)
        ws.moveIsland(id: c, before: nil)
        #expect(ws.islands.map(\.name) == ["Personal", "B", "C"])

        let p1 = makeProject("p1"), p2 = makeProject("p2"), p3 = makeProject("p3")
        for p in [p1, p2, p3] { ws.addProject(p, to: home) }
        ws.moveProject(id: p3.id, by: -1)
        #expect(ws.islands[0].projects.map(\.name) == ["p1", "p3", "p2"])
        ws.moveProject(id: p1.id, by: 1)
        #expect(ws.islands[0].projects.map(\.name) == ["p3", "p1", "p2"])
        ws.moveProject(id: p2.id, by: 1)
        #expect(ws.islands[0].projects.map(\.name) == ["p3", "p1", "p2"])
        // Never into another island.
        #expect(ws.islands[1].projects.isEmpty)
    }

    @Test func relocatingALinkedWorktreeOnlyMovesIt() {
        var (ws, p, main, other) = fixture()
        let moved = URL(fileURLWithPath: "/tmp/elsewhere/p-feat")
        let changes = ws.relocateWorktree(id: other.id, to: moved)
        #expect(changes.map(\.new) == [moved])
        #expect(ws.worktree(id: other.id)?.path == moved)
        #expect(ws.worktree(id: main.id)?.path == main.path)
        #expect(ws.project(id: p.id)?.folderURL == p.folderURL)
    }

    @Test func relocatingThePrimaryCheckoutMovesTheRepository() {
        var (ws, p, main, outside) = fixture()
        let inside = makeWorktree("p/.worktrees/fix", branch: "fix")
        ws.addWorktree(inside, to: p.id)
        ws.updateProject(id: p.id) {
            $0.worktreesDirectory = URL(fileURLWithPath: "/tmp/p/.worktrees")
            $0.dismissedWorktreePaths = ["/tmp/p/.worktrees/old", "/tmp/unrelated"]
        }
        let root = URL(fileURLWithPath: "/Users/me/code/p", isDirectory: true)

        let changes = ws.relocateWorktree(id: main.id, to: root)

        let project = try! #require(ws.project(id: p.id))
        #expect(Project.worktreeKey(project.folderURL) == "/Users/me/code/p")
        #expect(ws.worktree(id: main.id)?.path == root)
        #expect(ws.worktree(id: inside.id).map { Project.worktreeKey($0.path) } == "/Users/me/code/p/.worktrees/fix")
        // A worktree outside the repository folder did not move with it.
        #expect(ws.worktree(id: outside.id)?.path == outside.path)
        #expect(project.worktreesDirectory.map(Project.worktreeKey) == "/Users/me/code/p/.worktrees")
        #expect(project.dismissedWorktreePaths == ["/Users/me/code/p/.worktrees/old", "/tmp/unrelated"])
        #expect(Set(changes.map(\.old)) == [main.path, inside.path])
        // A sibling that only shares the name's prefix is not inside the repository.
        #expect(Workspace.rebase(URL(fileURLWithPath: "/tmp/p-feat"), from: URL(fileURLWithPath: "/tmp/p"), to: root) == nil)
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

    @Test func movingTheSelectedProjectAwaySelectsItsNeighbour() {
        var (ws, p, main, _) = fixture()
        let home = ws.islands[0].id
        let work = ws.addIsland(name: "Work")
        let q = Project(name: "q", folderURL: URL(fileURLWithPath: "/tmp/q"))
        ws.addProject(q, to: home)
        let feature = makeWorktree("q-feat", branch: "feat"), neighbour = makeWorktree("q", isMain: true)
        ws.addWorktree(feature, to: q.id)
        ws.addWorktree(neighbour, to: q.id)
        ws.selectWorktree(main.id)

        // Reordering within the island takes nothing away from it.
        ws.moveProject(id: p.id, to: home, at: 1)
        #expect(ws.selectedWorktreeIDByIsland[home] == main.id)

        ws.moveProject(id: p.id, to: work)
        #expect(ws.selectedWorktreeIDByIsland[home] == neighbour.id)
        #expect(ws.selectedWorktreeIDByIsland[work] == nil)
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
