import ArchipelCore
import XCTest

final class LaunchTests: ArchipelUITestCase {
    func testFirstLaunchShowsAnEmptyWorkspace() throws {
        try launch()

        assertExists(mainWindow.staticTexts["No Projects"], "An empty island should say it has no projects.")
        assertExists(mainWindow.buttons["Add Project…"], "The empty sidebar should offer to add a project.")
        assertExists(mainWindow.staticTexts["Nothing Selected"], "Without a worktree the content area has nothing to show.")
        XCTAssertEqual(sidebarWorktrees.count, 0)
        // Fresh defaults have no saved split positions, which is when a column can come out
        // narrower than the minimum it declares.
        let sidebar = mainWindow.descendants(matching: .any).matching(identifier: "sidebar").element(boundBy: 0)
        XCTAssertGreaterThanOrEqual(sidebar.frame.width, 220, "The sidebar should start at its minimum width or wider.")

        // Nothing to start a session in, add a worktree to or commit yet.
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(menuItem("File", "New Shell Session").isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["Project"].click()
        XCTAssertFalse(menuItem("Project", "Add Worktree…").isEnabled)
        XCTAssertFalse(menuItem("Project", "Commit…").isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testWorkspaceIsRestoredAfterRelaunch() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))

        chooseMenu("File", "New Shell Session")
        assertExists(tab("Shell 2"), "The second session should get a tab.")
        chooseMenu("Tab", "Rename Session…")
        let alert = mainWindow.sheets.element(boundBy: 0)
        assertExists(alert.textFields.element(boundBy: 0), "The rename alert did not come up.")
        replaceText(with: "Build")
        alert.buttons["Rename"].click()
        assertExists(tab("Build"), "The renamed session should show its new name.")
        showChanges()

        // The app saves a moment after each change; quitting is only safe to assert on once the
        // file says what the window shows.
        waitUntil("the workspace file holds both sessions") {
            try sandbox.savedWorkspace().allSessions.map(\.title) == ["Shell", "Build"]
        }
        quit()
        try launch(keepingState: true)

        assertExists(sidebarProject("fixture"), "The project should be back in the sidebar.")
        assertExists(sidebarWorktree("main"), "The main checkout should be back in the sidebar.")
        assertExists(tab("Shell"), "The first session's tab should be restored.")
        assertExists(tab("Build"), "The renamed session's tab should be restored.")
        XCTAssertTrue(tab("Build").isSelected, "The tab that was selected at quit should be selected again.")
        assertExists(commitMessageField, "The inspector should reopen on the Changes tab it was left on.")
    }
}
