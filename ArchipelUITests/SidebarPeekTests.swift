import ArchipelCore
import XCTest

/// Peeking at a worktree from the sidebar: Space under the pointer, arrows to browse, Return to open.
final class SidebarPeekTests: ArchipelUITestCase {
    /// Four rows in one project, in this order, with the main checkout selected. None has a session,
    /// so each peek is titled with the worktree's name.
    private func launchWithFourWorktrees() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let linked = try ["alpha", "beta", "gamma"].map { try repository.addWorktree(branch: $0, in: sandbox.worktreesRoot) }
        try launch(with: repository.workspace(linkedWorktrees: linked))
        assertExists(mainWindow(titled: "fixture - main"), "The main checkout should be selected at launch.")
    }

    /// Clicks the selected row so the list has keyboard focus without changing the selection, then
    /// puts the pointer over `row` and presses Space.
    private func peek(at row: String) {
        sidebarWorktree("main").click()
        sidebarWorktree(row).hover()
        app.typeKey(" ", modifierFlags: [])
        assertExists(peekTitle(row), "Space over \(row) should peek at it.")
    }

    func testArrowsBrowseThePeekWithoutMovingTheSelection() throws {
        try launchWithFourWorktrees()
        peek(at: "alpha")

        // Two in a row: the second used to reach the list while the popover moved between rows, and
        // selected a worktree for real.
        app.typeKey(.downArrow, modifierFlags: [])
        assertExists(peekTitle("beta"), "Down should move the peek to the next row.")
        app.typeKey(.downArrow, modifierFlags: [])
        assertExists(peekTitle("gamma"), "A second Down should move the peek again.")
        XCTAssertTrue(mainWindow(titled: "fixture - main").exists, "Browsing the peek must not change the selection.")

        app.typeKey(.upArrow, modifierFlags: [])
        assertExists(peekTitle("beta"), "Up should move the peek back.")
        XCTAssertTrue(mainWindow(titled: "fixture - main").exists, "Browsing the peek must not change the selection.")

        app.typeKey(.return, modifierFlags: [])
        assertExists(mainWindow(titled: "fixture - beta"), "Return should open the peeked worktree.")
        assertGone(peekTitle, "The peek should close once its worktree is open.")
    }

    func testSpaceAndEscapeCloseThePeek() throws {
        try launchWithFourWorktrees()

        peek(at: "beta")
        app.typeKey(.escape, modifierFlags: [])
        assertGone(peekTitle, "Escape should close the peek.")

        peek(at: "beta")
        app.typeKey(" ", modifierFlags: [])
        assertGone(peekTitle, "Space should close the peek again.")
        XCTAssertTrue(mainWindow(titled: "fixture - main").exists, "Closing a peek must not change the selection.")
    }
}
