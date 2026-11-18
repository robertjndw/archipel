import ArchipelCore
import XCTest

final class TabTests: ArchipelUITestCase {
    func testStartingTheFirstSessionFromAnEmptyWorktree() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        assertExists(mainWindow.staticTexts["No Tabs"], "A worktree without sessions should say so.")
        XCTAssertEqual(tabs.count, 0)
        mainWindow.buttons["Shell"].click()

        assertExists(tab("Shell"), "Starting a shell should open its tab.")
        assertGone(mainWindow.staticTexts["No Tabs"], "The placeholder should give way to the session.")
        waitUntil("the session is saved") { try sandbox.savedWorkspace().allSessions.map(\.title) == ["Shell"] }
    }

    func testOpeningSwitchingAndClosingTabs() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))

        assertExists(tab("Shell"), "The seeded session should have a tab.")
        chooseMenu("File", "New Shell Session")
        assertExists(tab("Shell 2"), "A second shell should be numbered.")
        XCTAssertTrue(tab("Shell 2").isSelected, "A new session is opened to be used, so it is selected.")
        XCTAssertFalse(tab("Shell").isSelected)

        tab("Shell").click()
        waitUntil("the clicked tab is selected") { self.tab("Shell").isSelected }
        chooseMenu("Tab", "Next Tab")
        waitUntil("Next Tab moves on") { self.tab("Shell 2").isSelected }
        // Wraps around at the end of the row.
        chooseMenu("Tab", "Next Tab")
        waitUntil("Next Tab wraps around") { self.tab("Shell").isSelected }
        chooseMenu("Tab", "Previous Tab")
        waitUntil("Previous Tab wraps around") { self.tab("Shell 2").isSelected }

        chooseMenu("File", "Close Tab")
        assertGone(tab("Shell 2"), "Close Tab should close the focused tab.")
        waitUntil("the neighbour takes the selection") { self.tab("Shell").isSelected }
        waitUntil("the closed session is gone from the workspace") {
            try sandbox.savedWorkspace().allSessions.map(\.title) == ["Shell"]
        }

        chooseMenu("File", "Close Tab")
        assertExists(mainWindow.staticTexts["No Tabs"], "Closing the last tab leaves the empty pane.")
        XCTAssertEqual(tabs.count, 0)
    }

    func testSplittingAPaneAndClosingItAgain() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell("One"), .shell("Two")]))

        assertExists(tab("Two"), "Both seeded sessions should have tabs.")
        XCTAssertEqual(panes.count, 1)
        tab("Two").click()
        waitUntil("the tab to split off is selected") { self.tab("Two").isSelected }
        chooseMenu("Tab", "Split Right")

        waitUntil("there are two panes") { self.panes.count == 2 }
        // Each pane shows one of the two sessions now, so both tabs are the selected one of theirs.
        XCTAssertTrue(tab("One").isSelected)
        XCTAssertTrue(tab("Two").isSelected)
        waitUntil("the split is saved") {
            try sandbox.savedWorkspace().allWorktrees[0].panes.map { $0.tabs.count } == [1, 1]
        }

        // A pane with a single tab has nothing left to split off.
        app.menuBars.menuBarItems["Tab"].click()
        XCTAssertFalse(menuItem("Tab", "Split Right").isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        // The new pane has the focus, so closing its only tab closes the pane with it.
        chooseMenu("File", "Close Tab")
        waitUntil("the emptied pane is gone") { self.panes.count == 1 }
        assertExists(tab("One"), "The other pane's tab should stay.")
        assertGone(tab("Two"), "The closed tab should be gone.")
    }

    func testRenamingASession() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))

        assertExists(tab("Shell"), "The seeded session should have a tab.")
        tab("Shell").rightClick()
        chooseContextMenu("Rename Session…")
        let alert = mainWindow.sheets.element(boundBy: 0)
        assertExists(alert.textFields.element(boundBy: 0), "The rename alert did not come up.")
        replaceText(with: "Dev Server")
        alert.buttons["Rename"].click()

        assertExists(tab("Dev Server"), "The tab should show the new name.")
        assertGone(tab("Shell"), "The old name should be gone.")
        waitUntil("the name is saved as the user's own") {
            let session = try sandbox.savedWorkspace().allSessions[0]
            return session.title == "Dev Server" && session.hasCustomTitle
        }
    }

    func testAShellSessionRunsInItsWorktree() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))

        assertExists(tab("Shell"), "The seeded session should have a tab.")
        // The terminal draws itself and has no accessibility tree to wait on, so the test keeps
        // typing the command until the shell has run it. Only letters and a space: those sit on
        // the same keys in every keyboard layout.
        let marker = repository.url.appending(path: "marker")
        let terminal = mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        waitUntil("the shell has created the file it was asked for", timeout: 30) {
            if FileManager.default.fileExists(atPath: marker.path) { return true }
            terminal.click()
            app.typeText("touch marker\n")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            return FileManager.default.fileExists(atPath: marker.path)
        }
    }
}
