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
