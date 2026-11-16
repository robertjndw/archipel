import Foundation
import Testing
@testable import ArchipelCore

struct DestinationTests {
    @Test func entriesFollowSidebarOrder() throws {
        let s1 = makeSession("Fix bug")
        var s2 = makeSession("Claude Code")
        s2.agentTitle = "Refactor"
        let feature = makeWorktree("feature", branch: "feat/x", sessions: [s2])
        var project = makeProject("Proj", sessions: [s1])
        project.worktrees.append(feature)

        var ws = Workspace()
        let first = ws.islands[0].id
        ws.addProject(project, to: first)
        let second = ws.addIsland(name: "Work")

        let entries = ws.destinationEntries()
        let mainWorktree = project.worktrees[0]
        #expect(entries.map(\.destination) == [
            .island(first), .worktree(mainWorktree.id), .session(s1.id),
            .worktree(feature.id), .session(s2.id), .island(second),
        ])
        #expect(entries.map(\.title) == ["Personal", "Proj", "Fix bug", "feat/x", "Refactor", "Work"])
        #expect(entries.map(\.subtitle) == [
            "1 project", "Personal / Proj", "Personal / Proj / Proj",
            "Personal / Proj", "Personal / Proj / feat/x", "0 projects",
        ])
    }
}
