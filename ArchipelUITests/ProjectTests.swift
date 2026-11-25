import ArchipelCore
import XCTest

final class ProjectTests: ArchipelUITestCase {
    func testAddingAProjectThroughTheFolderPicker() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch()

        mainWindow.buttons["Add Project…"].click()
        // The open panel's "Go to Folder", the one way to name a folder without clicking through
        // whatever the panel happens to show on this machine.
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goToField = app.sheets.textFields.element(boundBy: 0)
        assertExists(goToField, "The open panel did not show its Go to Folder field.")
        app.typeText(repository.url.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.buttons.matching(identifier: "Open").element(boundBy: 0)
        assertExists(open, "The open panel has no Open button.")
        waitUntil("the open panel accepts the folder") { open.isEnabled }
        open.click()

        assertExists(sidebarProject("fixture"), "The picked folder should become a project named after it.")
        assertExists(sidebarWorktree("main"), "The project's main checkout should be listed with its branch.")
        assertExists(mainWindow.staticTexts["No Tabs"], "A new project starts without sessions.")
        waitUntil("the project is saved") {
            try sandbox.savedWorkspace().islands[0].projects.map(\.folderURL.path) == [repository.url.path]
        }
    }

    func testRenamingAProject() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        assertExists(sidebarProject("fixture"), "The seeded project should be in the sidebar.")
        sidebarProject("fixture").rightClick()
        chooseContextMenu("Rename…")
        let alert = mainWindow.sheets.element(boundBy: 0)
        assertExists(alert.textFields.element(boundBy: 0), "The rename alert did not come up.")
        replaceText(with: "Renamed Project")
        alert.buttons["Rename"].click()

        assertExists(sidebarProject("Renamed Project"), "The sidebar should show the new name.")
        waitUntil("the new name is saved") {
            try sandbox.savedWorkspace().islands[0].projects.map(\.name) == ["Renamed Project"]
        }
        // Renaming is about the sidebar only.
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.url.path))
    }

    func testRenameIsDisabledWhileTheNameIsBlank() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        assertExists(sidebarProject("fixture"), "The seeded project should be in the sidebar.")
        sidebarProject("fixture").rightClick()
        chooseContextMenu("Rename…")
        let alert = mainWindow.sheets.element(boundBy: 0)
        assertExists(alert.textFields.element(boundBy: 0), "The rename alert did not come up.")
        let rename = alert.buttons["Rename"]
        waitUntil("Rename is enabled for the current name") { rename.isEnabled }

        // Spaces only: trimmed, that is no name at all.
        replaceText(with: "   ")
        waitUntil("Rename is disabled for a blank name") { !rename.isEnabled }
        replaceText(with: "Renamed")
        waitUntil("Rename is enabled again for a real name") { rename.isEnabled }
        alert.buttons["Cancel"].click()

        assertGone(alert, "Cancel should close the alert.")
        assertExists(sidebarProject("fixture"), "Cancel should keep the old name.")
        XCTAssertEqual(try sandbox.savedWorkspace().islands[0].projects.map(\.name), ["fixture"])
    }

    func testRemovingTheSelectedProjectSelectsTheNextOne() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        var workspace = Workspace()
        let alphaMain = Worktree(path: alpha.url, branch: "main", isMain: true)
        let betaMain = Worktree(path: beta.url, branch: "main", isMain: true)
        workspace.addProject(Project(name: "alpha", folderURL: alpha.url, worktrees: [alphaMain]), to: workspace.islands[0].id)
        workspace.addProject(Project(name: "beta", folderURL: beta.url, worktrees: [betaMain]), to: workspace.islands[0].id)
        workspace.selectWorktree(alphaMain.id)
        try launch(with: workspace)
        assertExists(mainWindow(titled: "alpha - main"), "The first project's checkout should be selected at launch.")

        sidebarProject("alpha").rightClick()
        chooseContextMenu("Remove Project…")
        let confirm = app.buttons.matching(identifier: "Remove Project").element(boundBy: 0)
        assertExists(confirm, "Removing a project should ask first.")
        confirm.click()

        assertGone(sidebarProject("alpha"), "The removed project should leave the sidebar.")
        assertExists(mainWindow(titled: "beta - main"), "The project that took its place should be selected.")
        XCTAssertFalse(mainWindow.staticTexts["No Projects"].exists, "An island with a project left is not empty.")
        waitUntil("the removal and the new selection are saved") {
            let saved = try sandbox.savedWorkspace()
            return saved.islands[0].projects.map(\.name) == ["beta"] && saved.selectedWorktreeID == betaMain.id
        }
    }

    func testRemovingAProjectLeavesItsFolderAlone() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))

        assertExists(sidebarProject("fixture"), "The seeded project should be in the sidebar.")
        sidebarProject("fixture").rightClick()
        chooseContextMenu("Remove Project…")
        let confirm = app.buttons.matching(identifier: "Remove Project").element(boundBy: 0)
        assertExists(confirm, "Removing a project should ask first.")
        confirm.click()

        assertExists(mainWindow.staticTexts["No Projects"], "The island should be empty again.")
        waitUntil("the removal is saved") { try sandbox.savedWorkspace().islands[0].projects.isEmpty }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.url.appending(path: "README.md").path))
        XCTAssertEqual(try repository.git("status", "--porcelain"), "")
    }
}
