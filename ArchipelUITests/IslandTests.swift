import ArchipelCore
import XCTest

final class IslandTests: ArchipelUITestCase {
    func testCreatingAnIslandAndSwitchingBack() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())
        assertExists(sidebarProject("fixture"), "The seeded project should be in the first island.")

        chooseMenu("Islands", "New Island…")
        let name = sheet.textFields.element(boundBy: 0)
        assertExists(name, "The island editor did not come up.")
        name.click()
        app.typeText("Work")
        sheet.buttons["Create"].click()

        // A new island is selected right away and starts empty.
        assertGone(sheet, "Creating the island should close its editor.")
        assertExists(mainWindow.buttons["Work"], "The switcher should list the new island.")
        assertExists(mainWindow.staticTexts["No Projects"], "The new island has no projects yet.")
        XCTAssertFalse(sidebarProject("fixture").exists, "Projects belong to the island they were added to.")
        waitUntil("the island is saved") { try sandbox.savedWorkspace().islands.map(\.name) == ["Personal", "Work"] }

        mainWindow.buttons["Personal"].click()
        assertExists(sidebarProject("fixture"), "Going back should bring the first island's projects back.")
        assertExists(mainWindow(titled: "fixture - main"), "The island remembers which worktree was selected in it.")
    }

    func testEachIslandKeepsItsScrollPosition() throws {
        // Enough projects that the list scrolls in the test window.
        let long = try (1...24).map { try sandbox.makeRepository(named: String(format: "repo%02d", $0)) }
        let other = try sandbox.makeRepository(named: "other")
        let third = try sandbox.makeRepository(named: "third")
        try launch(with: islandWorkspace([("Personal", long), ("Work", [other]), ("Play", [third])]))
        assertExists(sidebarProject("repo01"), "The first island's projects should be listed.")

        // Scrolled until it moves. On a slow CI runner a single scroll right after launch was
        // sometimes lost and the list stayed at the top.
        let sidebar = mainWindow.outlines["sidebar"]
        waitUntil("the first project is scrolled out of sight") {
            guard sidebarProject("repo01").isHittable else { return true }
            sidebar.scroll(byDeltaX: 0, deltaY: -2000)
            return false
        }
        assertExists(sidebarProject("repo24"), "Scrolling should reach the last project.")

        chooseMenu("Islands", "Work")
        assertExists(sidebarProject("other"), "The second island's project should be listed.")
        chooseMenu("Islands", "Personal")
        assertExists(sidebarProject("repo24"), "The first island's projects should be back.")
        waitUntil("the list is back where it was scrolled to") { sidebarProject("repo24").isHittable }
        XCTAssertFalse(sidebarProject("repo01").isHittable, "The list should not jump back to the top.")

        // The same once the first island's list is gone and has to be built again. Only the shown
        // island, its neighbours and the one visited last keep their lists, and from the third
        // island the first is none of these.
        chooseMenu("Islands", "Work")
        assertExists(sidebarProject("other"), "The second island's project should be listed.")
        chooseMenu("Islands", "Play")
        assertExists(sidebarProject("third"), "The third island's project should be listed.")
        chooseMenu("Islands", "Personal")
        assertExists(sidebarProject("repo24"), "The first island's projects should be back.")
        waitUntil("a rebuilt list is back where it was scrolled to") { sidebarProject("repo24").isHittable }
        XCTAssertFalse(sidebarProject("repo01").isHittable, "A rebuilt list should not start at the top.")
    }

    func testSwitchingIslandsFromTheMenu() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        let workspace = islandWorkspace([("Personal", [alpha]), ("Work", [beta])])
        try launch(with: workspace)
        let islands = workspace.islands.map(\.id)
        assertExists(mainWindow(titled: "alpha - main"), "The first island should be selected at launch.")

        chooseMenu("Islands", "Next Island")
        assertExists(mainWindow(titled: "beta - main"), "Next Island should show the second island's worktree.")
        assertExists(sidebarProject("beta"), "The second island lists its own projects.")
        XCTAssertFalse(sidebarProject("alpha").exists, "Projects belong to the island they were added to.")
        waitUntil("the selected island is saved") { try sandbox.savedWorkspace().selectedIslandID == islands[1] }

        // Wraps around at the end of the row.
        chooseMenu("Islands", "Next Island")
        assertExists(mainWindow(titled: "alpha - main"), "Next Island should wrap around to the first island.")
        chooseMenu("Islands", "Previous Island")
        assertExists(mainWindow(titled: "beta - main"), "Previous Island should wrap around to the last island.")

        // The menu lists the islands by name, each with the Control-digit shortcut. The key itself is
        // left alone: macOS can bind Control-digit to Mission Control desktops and swallow it.
        chooseMenu("Islands", "Personal")
        assertExists(mainWindow(titled: "alpha - main"), "Choosing an island by name should switch to it.")
        waitUntil("the first island is selected again in the saved workspace") {
            try sandbox.savedWorkspace().selectedIslandID == islands[0]
        }
    }

    func testNextIslandIsDisabledWithASingleIsland() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        assertExists(mainWindow(titled: "fixture - main"), "The seeded worktree should be selected.")
        app.menuBars.menuBarItems["Islands"].click()
        XCTAssertFalse(menuItem("Islands", "Next Island").isEnabled, "There is nowhere to go with one island.")
        XCTAssertFalse(menuItem("Islands", "Previous Island").isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testEditingAnIsland() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        let workspace = islandWorkspace([("Personal", [alpha]), ("Work", [beta])])
        try launch(with: workspace)

        assertExists(mainWindow.buttons["Work"], "The switcher should list both islands.")
        mainWindow.buttons["Work"].rightClick()
        chooseContextMenu("Edit Island…")
        let name = sheet.textFields.element(boundBy: 0)
        assertExists(name, "The island editor did not come up.")
        waitUntil("the editor starts from the island's current name") { name.value as? String == "Work" }
        name.click()
        replaceText(with: "Client")
        sheet.buttons["Save"].click()

        assertGone(sheet, "Saving should close the editor.")
        assertExists(mainWindow.buttons["Client"], "The switcher should show the new name.")
        assertGone(mainWindow.buttons["Work"], "The old name should be gone.")
        waitUntil("the new name is saved") { try sandbox.savedWorkspace().islands.map(\.name) == ["Personal", "Client"] }
        // Editing an island does not select it, so the one that was shown stays.
        assertExists(mainWindow(titled: "alpha - main"), "Renaming another island should not leave the selected one.")
        let saved = try sandbox.savedWorkspace()
        XCTAssertEqual(saved.islands[1].projects.map(\.name), ["beta"], "A rename must keep the island's projects.")
    }

    func testDeletingAnIslandAsksFirstAndRemovesItsProjects() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        var workspace = islandWorkspace([("Personal", [alpha]), ("Work", [beta])])
        // Select the island that is about to go, to see where the selection ends up.
        workspace.selectIsland(workspace.islands[1].id)
        try launch(with: workspace)
        assertExists(mainWindow(titled: "beta - main"), "The second island should be selected at launch.")

        mainWindow.buttons["Work"].rightClick()
        chooseContextMenu("Delete Island…")
        assertExists(sheet.buttons["Delete Island"], "An island with projects should ask before it goes.")
        sheet.buttons["Cancel"].click()
        assertGone(sheet, "Cancel should close the confirmation.")
        XCTAssertTrue(mainWindow.buttons["Work"].exists, "Cancel must keep the island.")
        XCTAssertEqual(try sandbox.savedWorkspace().islands.count, 2)

        mainWindow.buttons["Work"].rightClick()
        chooseContextMenu("Delete Island…")
        assertExists(sheet.buttons["Delete Island"], "The confirmation did not come up the second time.")
        sheet.buttons["Delete Island"].click()

        assertGone(mainWindow.buttons["Work"], "The island should be gone from the switcher.")
        assertExists(mainWindow(titled: "alpha - main"), "The selection should move to the island that is left.")
        assertExists(sidebarProject("alpha"), "The remaining island lists its project.")
        waitUntil("the deletion is saved with its projects") {
            let saved = try sandbox.savedWorkspace()
            return saved.islands.map(\.name) == ["Personal"] && saved.allWorktrees.map(\.path.lastPathComponent) == ["alpha"]
        }
        // Nothing is deleted from disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.url.path), "Removing a project must leave its folder alone.")
    }

    func testDeletingAnEmptyIslandNeedsNoConfirmation() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let workspace = islandWorkspace([("Personal", [repository]), ("Scratch", [])])
        try launch(with: workspace)

        assertExists(mainWindow.buttons["Scratch"], "The empty island should be in the switcher.")
        mainWindow.buttons["Scratch"].rightClick()
        chooseContextMenu("Delete Island")

        assertGone(mainWindow.buttons["Scratch"], "An empty island has nothing to lose and goes at once.")
        XCTAssertFalse(sheet.exists, "No confirmation is shown for an empty island.")
        waitUntil("the deletion is saved") { try sandbox.savedWorkspace().islands.map(\.name) == ["Personal"] }
    }

    func testMovingAnIslandChangesItsPlaceAndShortcut() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        try launch(with: islandWorkspace([("Personal", [alpha]), ("Work", [beta])]))

        assertExists(mainWindow.buttons["Work"], "Both islands should be in the switcher.")
        mainWindow.buttons["Work"].rightClick()
        chooseContextMenu("Move Left")
        waitUntil("the new order is saved") { try sandbox.savedWorkspace().islands.map(\.name) == ["Work", "Personal"] }

        chooseMenu("Islands", "Personal")
        assertExists(sidebarProject("alpha"), "Personal should still open.")
        app.typeKey("1", modifierFlags: .control)
        assertExists(sidebarProject("beta"), "⌃1 should follow the island that is now first.")
    }

    func testMovingAProjectDownWithinItsIsland() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        try launch(with: islandWorkspace([("Personal", [alpha, beta])]))

        sidebarProject("alpha").rightClick()
        chooseContextMenu("Move Down")
        waitUntil("the new order is saved") {
            try sandbox.savedWorkspace().islands.map { $0.projects.map(\.name) } == [["beta", "alpha"]]
        }
    }

    func testMovingAProjectUpStopsAtTheTop() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        let gamma = try sandbox.makeRepository(named: "gamma")
        try launch(with: islandWorkspace([("Personal", [alpha, beta, gamma])]))

        assertExists(sidebarProject("gamma"), "All seeded projects should be listed.")
        sidebarProject("gamma").rightClick()
        chooseContextMenu("Move Up")
        waitUntil("the new order is saved") {
            try sandbox.savedWorkspace().islands.map { $0.projects.map(\.name) } == [["alpha", "gamma", "beta"]]
        }

        sidebarProject("alpha").rightClick()
        XCTAssertEqual(shownMenuItem("Move Up")?.isEnabled, false, "The first project has nowhere to move up to.")
        XCTAssertEqual(shownMenuItem("Move Down")?.isEnabled, true, "The first project can still move down.")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testTheLastIslandCannotBeDeleted() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        assertExists(mainWindow.buttons["Personal"], "The default island should be in the switcher.")
        mainWindow.buttons["Personal"].rightClick()
        let candidates = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Delete Island"))
        waitUntil("the context menu shows Delete Island") {
            candidates.allElementsBoundByIndex.contains(where: \.isHittable)
        }
        let item = candidates.allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertEqual(item?.isEnabled, false, "The only island must stay.")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testMovingAProjectToAnotherIslandFollowsIt() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let gamma = try sandbox.makeRepository(named: "gamma")
        let beta = try sandbox.makeRepository(named: "beta")
        let workspace = islandWorkspace([("Personal", [alpha, gamma]), ("Work", [beta])])
        try launch(with: workspace)
        assertExists(sidebarProject("gamma"), "Both seeded projects should be in the first island.")

        sidebarProject("gamma").rightClick()
        chooseContextMenu("Move to Island")
        chooseContextMenu("Work")

        assertExists(sidebarProject("beta"), "The sidebar should follow the project to its new island.")
        assertExists(sidebarProject("gamma"), "The project should be in the island it was moved to.")
        XCTAssertFalse(sidebarProject("alpha").exists, "The sidebar should no longer show the island it left.")
        assertExists(mainWindow(titled: "gamma - main"), "The moved project's checkout should be selected.")
        waitUntil("the move is saved") {
            try sandbox.savedWorkspace().islands.map { $0.projects.map(\.name) } == [["alpha"], ["beta", "gamma"]]
        }

        chooseMenu("Islands", "Personal")
        assertExists(sidebarProject("alpha"), "The other project stays where it was.")
        XCTAssertFalse(sidebarProject("gamma").exists, "The moved project should be gone from its old island.")
    }

    func testMovingTheSelectedProjectAwayKeepsASelectionInTheIsland() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let gamma = try sandbox.makeRepository(named: "gamma")
        let beta = try sandbox.makeRepository(named: "beta")
        // alpha is first in the first island, so its main checkout is the selected worktree.
        let workspace = islandWorkspace([("Personal", [alpha, gamma]), ("Work", [beta])])
        try launch(with: workspace)
        assertExists(mainWindow(titled: "alpha - main"), "The first project's checkout should be selected at launch.")

        sidebarProject("alpha").rightClick()
        chooseContextMenu("Move to Island")
        chooseContextMenu("Work")

        assertExists(sidebarProject("beta"), "The sidebar should follow the project to its new island.")
        assertExists(mainWindow(titled: "alpha - main"), "The moved worktree should stay selected.")

        // Like removing a selected worktree, which falls back to the project's main checkout.
        chooseMenu("Islands", "Personal")
        assertExists(sidebarProject("gamma"), "The other project stays.")
        assertExists(mainWindow(titled: "gamma - main"), "A worktree of the island's remaining project should be selected.")
    }
}

/// The islands as `(name, repositories)`, each repository a project with its main checkout. The
/// first island is selected, and so is the main checkout of each island's first project.
private func islandWorkspace(_ islands: [(name: String, repositories: [FixtureRepository])]) -> Workspace {
    var workspace = Workspace(islands: [])
    var firstWorktrees: [Worktree.ID] = []
    for (name, repositories) in islands {
        let islandID = workspace.addIsland(name: name)
        for repository in repositories {
            let main = Worktree(path: repository.url, branch: "main", isMain: true)
            workspace.addProject(Project(name: repository.url.lastPathComponent, folderURL: repository.url, worktrees: [main]), to: islandID)
            if repository.url == repositories[0].url { firstWorktrees.append(main.id) }
        }
    }
    // Last, since selecting a worktree also selects its island.
    for id in firstWorktrees.reversed() { workspace.selectWorktree(id) }
    return workspace
}
