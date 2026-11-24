import AppKit
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
        // Before 27.2 the panes are laid out by hand, without a split view, and always start out equal.
        if #available(macOS 27.2, *) {
            let position = try XCTUnwrap(paneDividerPosition, "The panes should sit in a split view.")
            XCTAssertEqual(position, 0.5, accuracy: 0.02, "A new split should give both panes half the width.")
        }
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

    func testUndoingCloseTabAndSplit() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let sessions = [Session.shell("One"), .shell("Two"), .shell("Three")]
        try launch(with: repository.workspace(sessions: sessions))

        assertExists(tab("Two"), "The seeded sessions should have tabs.")
        tab("Two").click()
        waitUntil("the tab to close is selected") { self.tab("Two").isSelected }
        chooseMenu("File", "Close Tab")
        assertGone(tab("Two"), "Close Tab should close the focused tab.")

        // The same session comes back, so an agent would resume its conversation.
        undo()
        assertExists(tab("Two"), "Undo should bring the closed tab back.")
        XCTAssertTrue(tab("Two").isSelected, "The reopened tab should be selected.")
        waitUntil("the session is back in its place") {
            try sandbox.savedWorkspace().allWorktrees[0].panes[0].tabs.map(\.content)
                == sessions.map { .session($0.id) }
        }

        redo()
        assertGone(tab("Two"), "Redo should close the tab again.")
        undo()
        assertExists(tab("Two"), "A second undo should bring it back again.")

        tab("Three").click()
        waitUntil("the tab to split off is selected") { self.tab("Three").isSelected }
        chooseMenu("Tab", "Split Right")
        waitUntil("there are two panes") { self.panes.count == 2 }
        undo()
        waitUntil("the split is undone") { self.panes.count == 1 }
        waitUntil("the tab is back where it was") {
            try sandbox.savedWorkspace().allWorktrees[0].panes.map { $0.tabs.map(\.content) }
                == [sessions.map { .session($0.id) }]
        }
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

    func testUndoingARename() throws {
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

        undo()
        assertExists(tab("Shell"), "Undo should bring the old name back.")
        // The old name was the automatic one, so the session goes back to following its title.
        waitUntil("the automatic name is saved again") {
            let session = try sandbox.savedWorkspace().allSessions[0]
            return session.title == "Shell" && !session.hasCustomTitle
        }

        redo()
        assertExists(tab("Dev Server"), "Redo should rename it again.")
    }

    /// The editor keeps an undo stack of its own. ⌘Z while typing must take back the typing, not
    /// reopen a tab that was closed before.
    func testUndoInTheEditorUndoesTyping() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell("One"), .shell("Two")]))

        assertExists(tab("Two"), "The seeded sessions should have tabs.")
        tab("Two").click()
        waitUntil("the tab to close is selected") { self.tab("Two").isSelected }
        chooseMenu("File", "Close Tab")
        assertGone(tab("Two"), "Close Tab should close the focused tab.")

        app.typeKey("p", modifierFlags: .command)
        assertExists(paletteField, "Open Quickly did not come up.")
        app.typeText("notes.txt")
        let row = paletteRow(startingWith: "notes.txt")
        assertExists(row, "Open Quickly should list notes.txt.")
        row.click()
        let editor = fileEditorTextView
        assertExists(editor, "The file should open in the editor.")
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("typed")
        waitUntil("the editor has the typed text") { (editor.value as? String)?.contains("typed") == true }

        app.typeKey("z", modifierFlags: .command)
        waitUntil("the typing is undone") { (editor.value as? String)?.contains("typed") == false }
        XCTAssertFalse(tab("Two").exists, "⌘Z in the editor must not reopen the closed tab.")
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

    func testCopyPathOfAFileTab() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        app.typeKey("p", modifierFlags: .command)
        assertExists(paletteField, "⌘P should open the palette.")
        app.typeText("notes")
        assertExists(paletteRow(startingWith: "notes.txt"), "The worktree's files should be searchable.")
        app.typeKey(.return, modifierFlags: [])
        assertExists(tab("notes.txt"), "The file should open in a tab.")

        // The test runner shares the pasteboard with the app, so it starts out empty to make the
        // copy the only thing that can be on it.
        NSPasteboard.general.clearContents()
        tab("notes.txt").rightClick()
        chooseContextMenu("Copy Path")

        let expected = repository.url.appending(path: "notes.txt").resolvingSymlinksInPath().path
        waitUntil("the file's path is on the pasteboard") {
            guard let copied = NSPasteboard.general.string(forType: .string) else { return false }
            return URL(fileURLWithPath: copied).resolvingSymlinksInPath().path == expected
        }
    }

    func testOpenFileFromADiffTab() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("notes.txt", "first line\nsecond line\n")
        try launch(with: repository.workspace())

        showChanges()
        assertExists(unstagedChange("notes.txt"), "The modified file should be listed.")
        unstagedChange("notes.txt").doubleClick()
        assertExists(tab("notes.txt"), "Opening a change should give its diff a tab.")
        waitUntil("the diff tab is saved") {
            try self.sandbox.savedWorkspace().allWorktrees[0].panes[0].tabs.map(\.content) == [.diff(path: "notes.txt", staged: false)]
        }

        tab("notes.txt").rightClick()
        chooseContextMenu("Open File")

        assertExists(fileEditorTextView, "Open File should show the file in the editor.")
        waitUntil("the file has a tab of its own next to the diff") {
            let contents = try self.sandbox.savedWorkspace().allWorktrees[0].panes[0].tabs.map(\.content)
            return contents.count == 2 && contents.contains { content in
                if case .file(let url) = content { return url.lastPathComponent == "notes.txt" }
                return false
            }
        }
        waitUntil("the editor shows the file as it is on disk") {
            (self.fileEditorTextView.value as? String)?.contains("second line") == true
        }
    }
}
