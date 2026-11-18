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
}
