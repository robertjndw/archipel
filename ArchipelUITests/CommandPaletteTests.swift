import ArchipelCore
import XCTest

final class CommandPaletteTests: ArchipelUITestCase {
    func testFilteringAndRunningACommand() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "⌘K should open the palette.")
        XCTAssertGreaterThan(paletteRows.count, 1, "The empty palette lists what there is to go to.")

        app.typeText("new shell")
        let command = paletteRow(startingWith: "New Shell Session")
        assertExists(command, "Typing should narrow the list to the matching command.")
        waitUntil("the best match is selected") { command.isSelected }
        assertGone(paletteRow(startingWith: "Add Project"), "Commands that do not match should be filtered out.")

        app.typeKey(.return, modifierFlags: [])
        assertGone(paletteField, "Running a command closes the palette.")
        assertExists(tab("Shell"), "The command should have started a shell session.")
    }

    func testEscapeDismissesWithoutRunningAnything() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        chooseMenu("Go", "Go to…")
        assertExists(paletteField, "Go to… should open the palette.")
        app.typeText("new shell")
        assertExists(paletteRow(startingWith: "New Shell Session"), "The command should be listed.")
        app.typeKey(.escape, modifierFlags: [])

        assertGone(paletteField, "Escape should close the palette.")
        XCTAssertEqual(tabs.count, 0, "Dismissing must not run the selected command.")
    }

    func testJumpingToAnotherWorktree() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        assertExists(mainWindow(titled: "fixture - main"),
                     "The main checkout should be selected at launch.")
        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "⌘K should open the palette.")
        app.typeText("feature")
        let destination = paletteRow(startingWith: "feature")
        assertExists(destination, "The other worktree should be offered as a destination.")
        destination.click()

        assertGone(paletteField, "Going somewhere closes the palette.")
        assertExists(mainWindow(titled: "fixture - feature"),
                     "The chosen worktree should be selected.")
    }

    func testOpeningAFileQuickly() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        app.typeKey("p", modifierFlags: .command)
        assertExists(paletteField, "⌘P should open the palette.")
        app.typeText("notes")
        let file = paletteRow(startingWith: "notes.txt")
        assertExists(file, "The worktree's files should be searchable.")
        app.typeKey(.return, modifierFlags: [])

        assertGone(paletteField, "Opening a file closes the palette.")
        assertExists(tab("notes.txt"), "The file should open in a tab.")
    }

    /// The palette is in front of the tabs, so ⌘W belongs to it.
    func testCommandWDismissesThePaletteAndClosesNoTab() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")

        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "⌘K should open the palette.")
        app.typeKey("w", modifierFlags: .command)

        assertGone(paletteField, "⌘W should dismiss the palette.")
        XCTAssertTrue(tab("Shell").exists, "⌘W with the palette open must not close the tab behind it.")
        XCTAssertEqual(try sandbox.savedWorkspace().allSessions.count, 1)
    }

    /// A click on a row must not also count as a click into the pane underneath it, which would
    /// focus that pane before the command runs.
    func testClickingARowOverTheOtherPaneActsOnTheFocusedPane() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let workspace = repository.splitWorkspace(panes: [[.shell("Left")], [.shell("Right")]], focusedPane: 1)
        try launch(with: workspace)
        assertExists(tab("Right"), "Both seeded sessions should have tabs.")
        let leftTerminal = terminalsLeftToRight(2)[0]

        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "⌘K should open the palette.")
        app.typeText("close tab")
        let row = paletteRow(startingWith: "Close Tab")
        assertExists(row, "Close Tab should be offered while a tab is focused.")
        let inset: CGFloat = 24
        XCTAssertLessThan(row.frame.minX + inset, leftTerminal.frame.maxX, "The row should reach over the left pane for this test to mean anything.")
        row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: inset, dy: row.frame.height / 2)).click()

        assertGone(paletteField, "Running a command closes the palette.")
        assertGone(tab("Right"), "Close Tab should close the focused right pane's tab.")
        XCTAssertTrue(tab("Left").exists, "The pane under the click must not have taken the focus.")
        waitUntil("only the left session is saved") { try self.sandbox.savedWorkspace().allSessions.map(\.title) == ["Left"] }
    }

    func testThePaletteDoesNotOpenOverASheet() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")

        chooseMenu("Tab", "Rename Session…")
        assertExists(sheet.textFields.element(boundBy: 0), "The rename alert did not come up.")
        app.typeKey("k", modifierFlags: .command)
        sheet.buttons["Cancel"].click()
        assertGone(sheet, "Cancel should dismiss the rename alert.")
        // Had ⌘K opened the palette behind the sheet, it would still be there now.
        XCTAssertFalse(paletteField.exists, "The palette must not open while a sheet is up.")

        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "Without the sheet ⌘K should open the palette again.")
    }

    func testFocusPaneCommandsAreListedWithTwoPanes() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let workspace = repository.splitWorkspace(panes: [[.shell("Left")], [.shell("Right")]])
        try launch(with: workspace)
        assertExists(tab("Right"), "Both seeded sessions should have tabs.")

        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "⌘K should open the palette.")
        app.typeText("focus")
        assertExists(paletteRow(startingWith: "Focus Previous Pane"), "Focus Previous Pane should be offered with two panes.")
        let next = paletteRow(startingWith: "Focus Next Pane")
        assertExists(next, "Focus Next Pane should be offered with two panes.")
        next.click()

        assertGone(paletteField, "Running a command closes the palette.")
        let right = workspace.allWorktrees[0].panes[1].id
        waitUntil("the right pane is focused") { try self.sandbox.savedWorkspace().allWorktrees[0].focusedPaneID == right }
    }

    func testIslandAndProjectCommandsAreListed() throws {
        let alpha = try sandbox.makeRepository(named: "alpha")
        let beta = try sandbox.makeRepository(named: "beta")
        var workspace = Workspace(islands: [])
        let personal = workspace.addIsland(name: "Personal")
        let alphaMain = Worktree(path: alpha.url, branch: "main", isMain: true)
        workspace.addProject(Project(name: "alpha", folderURL: alpha.url, worktrees: [alphaMain]), to: personal)
        let work = workspace.addIsland(name: "Work")
        let betaMain = Worktree(path: beta.url, branch: "main", isMain: true)
        workspace.addProject(Project(name: "beta", folderURL: beta.url, worktrees: [betaMain]), to: work)
        workspace.selectWorktree(alphaMain.id)
        try launch(with: workspace)
        assertExists(mainWindow(titled: "alpha - main"), "The first island should be selected at launch.")

        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "⌘K should open the palette.")
        app.typeText("island")
        assertExists(paletteRow(startingWith: "Edit Island"), "The selected island should be editable from the palette.")
        assertExists(paletteRow(startingWith: "Delete Island"), "With another island left, this one can be deleted.")

        replaceText(with: "move project")
        let move = paletteRow(startingWith: "Move Project to Work")
        assertExists(move, "The project should be movable to the other island.")
        XCTAssertFalse(paletteRow(startingWith: "Move Project to Personal").exists, "The project's own island is no destination.")
        move.click()

        assertGone(paletteField, "Running a command closes the palette.")
        waitUntil("the project is saved in the other island") {
            try self.sandbox.savedWorkspace().island(id: work)?.projects.map(\.name).sorted() == ["alpha", "beta"]
        }
        assertExists(mainWindow(titled: "alpha - main"), "The moved project's worktree should stay selected.")
    }
}
