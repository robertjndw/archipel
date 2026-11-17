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
}
