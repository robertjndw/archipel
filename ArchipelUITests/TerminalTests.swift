import ArchipelCore
import XCTest

/// The terminal of a shell tab: its scrollback search and what happens once its shell has exited.
final class TerminalTests: ArchipelUITestCase {
    private var exitedBar: XCUIElement {
        let ended = "This session has ended."
        let failed = "This session exited with code"
        return mainWindow.staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@ OR label BEGINSWITH %@ OR value BEGINSWITH %@", ended, ended, failed, failed))
            .element(boundBy: 0)
    }

    /// Launches with one shell and waits until it has run a first command, so it is at its prompt.
    private func launchWithAShellAtItsPrompt(_ repository: FixtureRepository) throws -> XCUIElement {
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")
        let terminal = terminalSurfaces.element(boundBy: 0)
        assertExists(terminal, "The shell's terminal should be on screen.")
        let marker = repository.url.appending(path: "ready")
        runInTerminal("touch ready", in: terminal) { FileManager.default.fileExists(atPath: marker.path) }
        return terminal
    }

    // MARK: Search

    func testSearchingTheTerminal() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let terminal = try launchWithAShellAtItsPrompt(repository)
        // The command line stays on screen, so the word is there to be found.
        let word = repository.url.appending(path: "zebrafish")
        runInTerminal("touch zebrafish", in: terminal) { FileManager.default.fileExists(atPath: word.path) }

        app.typeKey("f", modifierFlags: .command)
        assertExists(terminalSearchField, "⌘F in a terminal should open its search.")
        app.typeText("zebrafish")
        let count = terminalSearchBar.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@ OR value MATCHES %@", "[0-9]+ (of [0-9]+|match(es)?)", "[0-9]+ (of [0-9]+|match(es)?)"))
            .element(boundBy: 0)
        assertExists(count, "The search should count the matches of a word that is on screen.")

        app.typeKey(.escape, modifierFlags: [])
        assertGone(terminalSearchBar, "Escape should close the search.")
        // Typed without a click: closing the search has to give the keyboard back to the shell.
        let after = repository.url.appending(path: "afterfind")
        app.typeText("touch afterfind\n")
        waitUntil("the shell gets the keys again") { FileManager.default.fileExists(atPath: after.path) }
    }

    func testFindInAFileOpensTheEditorsOwnFindBar() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        app.typeKey("p", modifierFlags: .command)
        assertExists(paletteField, "⌘P should open the palette.")
        app.typeText("notes")
        assertExists(paletteRow(startingWith: "notes.txt"), "The worktree's files should be searchable.")
        app.typeKey(.return, modifierFlags: [])
        assertExists(fileEditorTextView, "The file should open in the editor.")
        fileEditorTextView.click()

        // The inspector may have search fields of its own, so the find bar is told by the count.
        let searchFields = mainWindow.searchFields
        let before = searchFields.count
        app.typeKey("f", modifierFlags: .command)
        waitUntil("the editor shows its find bar") { searchFields.count > before }
        XCTAssertFalse(terminalSearchBar.exists, "A file tab has no terminal to search.")
    }

    // MARK: Exited sessions

    func testAnExitedShellRestartsOnReturn() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let terminal = try launchWithAShellAtItsPrompt(repository)

        app.typeText("exit\n")
        assertExists(exitedBar, "The tab should say its shell has exited.")
        XCTAssertEqual(tabs.count, 1, "An exited session keeps its tab.")

        // The terminal still has the keyboard, and Return there is the bar's Restart.
        app.typeKey(.return, modifierFlags: [])
        assertGone(exitedBar, "Return should restart the session.")
        let restarted = repository.url.appending(path: "restarted")
        runInTerminal("touch restarted", in: terminal) { FileManager.default.fileExists(atPath: restarted.path) }
        XCTAssertEqual(tabs.count, 1, "A restart keeps the same tab.")
    }

    func testClosingAnExitedShellDoesNotAsk() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        _ = try launchWithAShellAtItsPrompt(repository)

        app.typeText("exit\n")
        assertExists(exitedBar, "The tab should say its shell has exited.")

        app.typeKey("w", modifierFlags: .command)
        waitUntil("the tab is gone") { self.tabs.count == 0 }
        XCTAssertFalse(sheet.exists, "Nothing runs in an exited session, so there is nothing to ask about.")
        waitUntil("the session is gone from the workspace") { try self.sandbox.savedWorkspace().allSessions.isEmpty }
    }
}
