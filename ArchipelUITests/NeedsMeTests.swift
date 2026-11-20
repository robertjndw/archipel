import ArchipelCore
import XCTest

/// The sidebar's "Needs Me" filter: only the worktrees that wait on the user, from every island.
final class NeedsMeTests: ArchipelUITestCase {
    private var filterButton: XCUIElement {
        mainWindow.buttons.matching(identifier: "sidebar.needsMe").element(boundBy: 0)
    }

    func testFilterListsTheWaitingWorktreeOfAnotherIslandAndOpensIt() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        let waiting = Session.claude()

        var workspace = Workspace(islands: [])
        let personal = workspace.addIsland(name: "Personal")
        let work = workspace.addIsland(name: "Work")
        let alphaMain = Worktree(path: alpha.url, branch: "main", isMain: true)
        let betaMain = Worktree(path: beta.url, branch: "main", isMain: true, sessions: [waiting])
        workspace.addProject(Project(name: "alpha", folderURL: alpha.url, worktrees: [alphaMain]), to: personal)
        workspace.addProject(Project(name: "beta", folderURL: beta.url, worktrees: [betaMain]), to: work)
        // Last, since selecting a worktree also selects its island.
        workspace.selectWorktree(betaMain.id)
        workspace.selectWorktree(alphaMain.id)
        try launch(with: workspace)
        assertExists(mainWindow(titled: "alpha - main"), "The first island should be selected at launch.")

        // Nothing waits yet.
        assertExists(filterButton, "The sidebar header should have the filter.")
        filterButton.click()
        assertExists(mainWindow.staticTexts["Nothing Needs You"], "With nothing waiting the filter should say so.")
        XCTAssertFalse(sidebarProject("alpha").exists, "The filter hides what does not need the user.")
        assertGone(mainWindow.buttons["Work"], "The island switcher has no use while the list spans every island.")

        // Sent as the agent's hook would, to a session in an island the user is not looking at.
        try sendHook(["hook_event_name": "PermissionRequest", "session_id": "waiting-conversation", "tool_name": "Bash"],
                     hook: hookHelper.path, sessionID: waiting.id.uuidString, socket: hookSocket)
        assertExists(sidebarProject("beta"), "The waiting worktree of the other island should be listed.")
        assertGone(mainWindow.staticTexts["Nothing Needs You"], "The empty state should give way to the list.")
        assertExists(mainWindow.staticTexts["Work"], "The list should name the island the worktree is in.")
        XCTAssertFalse(sidebarProject("alpha").exists, "Only the worktree that waits is listed.")
        XCTAssertTrue(mainWindow(titled: "alpha - main").exists, "A request must not move the selection by itself.")

        sidebarWorktree("main").click()
        assertExists(mainWindow(titled: "beta - main"), "Clicking the row should switch to its island and select the worktree.")
        // Opening it answers the request, yet the row stays while it is selected so the list holds still.
        waitUntil("the window shows nothing waiting any more") { !self.agentsStatus.contains("waiting") }
        XCTAssertTrue(sidebarProject("beta").exists, "The selected worktree should stay listed under the pointer.")

        // The menu command turns the filter off again, and the switcher comes back.
        chooseMenu("Tab", "Show All in Sidebar")
        assertExists(mainWindow.buttons["Personal"], "The island switcher should return with the full sidebar.")
        assertExists(sidebarProject("beta"), "The selected island's projects should be listed again.")

        // Once something else is selected the dealt-with worktree is gone from the filtered list.
        mainWindow.buttons["Personal"].click()
        assertExists(mainWindow(titled: "alpha - main"), "The island remembers its selected worktree.")
        filterButton.click()
        assertExists(mainWindow.staticTexts["Nothing Needs You"], "A request that was dealt with should not be listed.")
    }
}
