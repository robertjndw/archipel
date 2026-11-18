import ArchipelCore
import XCTest

final class NavigationTests: ArchipelUITestCase {
    func testSwitchingToTheRecentTabAndBack() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell("One"), .shell("Two"), .shell("Three")]))

        assertExists(tab("Three"), "The seeded sessions should have tabs.")
        tab("One").click()
        waitUntil("the first tab is selected") { self.tab("One").isSelected }
        tab("Three").click()
        waitUntil("the third tab is selected") { self.tab("Three").isSelected }

        // The menu item runs the same gesture as Control-Tab but does not depend on seeing the key
        // released, which synthetic key events do not always report.
        chooseMenu("Go", "Switch to Recent Tab")
        waitUntil("the previously used tab comes back") { self.tab("One").isSelected }
        XCTAssertFalse(self.tab("Three").isSelected)
        XCTAssertFalse(self.tab("Two").isSelected, "A tab that was never visited is not the recent one.")

        chooseMenu("Go", "Switch to Recent Tab")
        waitUntil("switching again flips back") { self.tab("Three").isSelected }
    }

    func testClickingWorktreesShowsTheirTabs() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        let linked = Worktree(path: feature.path, branch: "feature", sessions: [.shell("Feature Shell")])
        try launch(with: repository.workspace(sessions: [.shell("Main Shell")], linkedWorktrees: [linked]))

        assertExists(mainWindow(titled: "fixture - main"), "The main checkout should be selected at launch.")
        assertExists(tab("Main Shell"), "The main checkout shows its own session.")
        XCTAssertFalse(tab("Feature Shell").exists, "Another worktree's tabs are not shown.")

        sidebarWorktree("feature").click()
        assertExists(mainWindow(titled: "fixture - feature"), "Clicking a row should put its branch in the title.")
        assertExists(tab("Feature Shell"), "The selected worktree's tab should be shown.")
        assertGone(tab("Main Shell"), "The previous worktree's tab should give way.")
        waitUntil("the selection is saved") {
            let saved = try sandbox.savedWorkspace()
            return saved.selectedWorktreeID == saved.allWorktrees.first { $0.branch == "feature" }?.id
        }

        sidebarWorktree("main").click()
        assertExists(mainWindow(titled: "fixture - main"), "Clicking the first row should go back.")
        assertExists(tab("Main Shell"), "Going back shows the first worktree's tab again.")
        assertGone(tab("Feature Shell"), "The other worktree's tab should be gone again.")
    }

    func testGoingToAnIslandFromThePalette() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        let workspace = twoIslandWorkspace(alpha: alpha, beta: beta)
        try launch(with: workspace)
        assertExists(mainWindow(titled: "alpha - main"), "The first island should be selected at launch.")

        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "⌘K should open the palette.")
        app.typeText("Work")
        // An island's row says how many projects it holds, which tells it from the worktrees.
        let island = paletteRow(startingWith: "Work, 1 project")
        assertExists(island, "Islands should be offered as destinations.")
        island.click()

        assertGone(paletteField, "Going somewhere closes the palette.")
        assertExists(mainWindow(titled: "beta - main"), "The island's selected worktree should be shown.")
        assertExists(sidebarProject("beta"), "The sidebar should list the chosen island's projects.")
        waitUntil("the island is saved as selected") { try sandbox.savedWorkspace().selectedIslandID == workspace.islands[1].id }
    }

    func testGoingToASessionInAnotherIslandFromThePalette() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        let workspace = twoIslandWorkspace(alpha: alpha, beta: beta)
        try launch(with: workspace)
        assertExists(mainWindow(titled: "alpha - main"), "The first island should be selected at launch.")
        XCTAssertFalse(tab("Build").exists, "The session lives in the other island.")

        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "⌘K should open the palette.")
        app.typeText("Build")
        let session = paletteRow(startingWith: "Build, ")
        assertExists(session, "Sessions of every island should be offered as destinations.")
        session.click()

        assertGone(paletteField, "Going somewhere closes the palette.")
        assertExists(mainWindow(titled: "beta - main"), "The session's island and worktree should be selected.")
        assertExists(tab("Build"), "The session's tab should be shown.")
        waitUntil("the session's tab is selected") { self.tab("Build").isSelected }
        waitUntil("the island is saved as selected") { try sandbox.savedWorkspace().selectedIslandID == workspace.islands[1].id }
    }
}

/// "Personal" holds `alpha` and "Work" holds `beta`, which has one session called Build. Personal
/// is selected.
private func twoIslandWorkspace(alpha: FixtureRepository, beta: FixtureRepository) -> Workspace {
    var workspace = Workspace(islands: [])
    let personal = workspace.addIsland(name: "Personal")
    let alphaMain = Worktree(path: alpha.url, branch: "main", isMain: true)
    workspace.addProject(Project(name: "alpha", folderURL: alpha.url, worktrees: [alphaMain]), to: personal)
    let work = workspace.addIsland(name: "Work")
    let betaMain = Worktree(path: beta.url, branch: "main", isMain: true, sessions: [.shell("Build")])
    workspace.addProject(Project(name: "beta", folderURL: beta.url, worktrees: [betaMain]), to: work)
    workspace.selectWorktree(betaMain.id)
    // Last, since selecting a worktree also selects its island.
    workspace.selectWorktree(alphaMain.id)
    return workspace
}
