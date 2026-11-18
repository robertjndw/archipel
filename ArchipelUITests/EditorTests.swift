import ArchipelCore
import XCTest

final class EditorTests: ArchipelUITestCase {
    /// Opens a file the way the keyboard does and waits for its tab.
    private func openQuickly(_ fileName: String) {
        app.typeKey("p", modifierFlags: .command)
        assertExists(paletteField, "Open Quickly did not come up.")
        app.typeText(fileName)
        let row = paletteRow(startingWith: fileName)
        assertExists(row, "Open Quickly should list \(fileName).")
        row.click()
        assertExists(tab(fileName), "Opening a file should give it a tab.")
        assertExists(editor, "The tab should show the editor.")
    }

    /// Puts the cursor at the end of the file and types there. Clicking alone would leave the
    /// cursor wherever the click landed, and the text on disk is only checked by what it contains.
    private func append(_ text: String) {
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(text)
    }

    private var editor: XCUIElement { mainWindow.textViews.element(boundBy: 0) }

    private func contents(of file: String, in repository: FixtureRepository) -> String? {
        try? String(contentsOf: repository.url.appending(path: file), encoding: .utf8)
    }

    func testSavingAnEditWritesTheFileAndListsItAsChanged() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        openQuickly("notes.txt")
        append("second line")
        XCTAssertEqual(contents(of: "notes.txt", in: repository), "first line\n", "Typing alone must not touch the file.")
        // The dot on the tab is all a sighted user gets, so VoiceOver has to say it.
        waitUntil("the tab says it has unsaved changes") { self.tab("notes.txt").value as? String == "Unsaved changes" }

        chooseMenu("File", "Save")
        waitUntil("the edit is on disk") { self.contents(of: "notes.txt", in: repository)?.contains("second line") == true }
        waitUntil("the tab no longer says so") { self.tab("notes.txt").value as? String != "Unsaved changes" }
        XCTAssertTrue(contents(of: "notes.txt", in: repository)?.hasPrefix("first line\n") == true, "The original text should be kept.")

        showChanges()
        assertExists(unstagedChange("notes.txt"), "The saved file should be listed as modified.")
        waitUntil("git sees the file as modified") { try repository.git("status", "--porcelain") == "M notes.txt" }

        // Nothing is dirty any more, so Save has nothing to do.
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(menuItem("File", "Save").isEnabled, "A saved file leaves nothing to save.")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSaveAllWritesEveryDirtyFile() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        openQuickly("notes.txt")
        append("more notes")
        openQuickly("README.md")
        append("more readme")

        // Neither is saved until asked, whichever tab is in front.
        XCTAssertEqual(contents(of: "notes.txt", in: repository), "first line\n")
        XCTAssertEqual(contents(of: "README.md", in: repository), "# fixture\n")

        chooseMenu("File", "Save All")
        waitUntil("both files are on disk") {
            self.contents(of: "notes.txt", in: repository)?.contains("more notes") == true
                && self.contents(of: "README.md", in: repository)?.contains("more readme") == true
        }
        waitUntil("git sees both files as modified") {
            // Not --porcelain: the helper trims its output, which strips the leading space of
            // only the first " M" line.
            try repository.git("diff", "--name-only").split(separator: "\n").sorted() == ["README.md", "notes.txt"]
        }
    }

    func testDontSaveWhenClosingADirtyTabLeavesTheFileAlone() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        openQuickly("notes.txt")
        append("scribble")
        chooseMenu("File", "Close Tab")

        let question = mainWindow.sheets.element(boundBy: 0)
        assertExists(question.staticTexts["Do you want to save the changes you made to notes.txt?"],
                     "Closing a file with unsaved edits should ask first.")
        XCTAssertTrue(tab("notes.txt").exists, "The tab stays until the question is answered.")
        question.buttons["Don't Save"].click()

        assertGone(tab("notes.txt"), "Don't Save should still close the tab.")
        XCTAssertEqual(contents(of: "notes.txt", in: repository), "first line\n", "Discarded edits must not reach the disk.")
        XCTAssertEqual(try repository.git("status", "--porcelain"), "")
    }

    func testSaveWhenClosingADirtyTabWritesTheFile() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        openQuickly("notes.txt")
        append("kept")
        chooseMenu("File", "Close Tab")

        let question = mainWindow.sheets.element(boundBy: 0)
        assertExists(question.buttons["Save"], "Closing a file with unsaved edits should ask first.")
        question.buttons["Save"].click()

        assertGone(tab("notes.txt"), "Save should close the tab afterwards.")
        waitUntil("the edit is on disk") { self.contents(of: "notes.txt", in: repository)?.contains("kept") == true }
    }

    func testCancelKeepsTheDirtyTabOpen() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        openQuickly("notes.txt")
        append("pending")
        chooseMenu("File", "Close Tab")

        let question = mainWindow.sheets.element(boundBy: 0)
        assertExists(question.buttons["Cancel"], "Closing a file with unsaved edits should ask first.")
        question.buttons["Cancel"].click()

        assertGone(question, "Cancel should dismiss the question.")
        XCTAssertTrue(tab("notes.txt").exists, "Cancel should leave the tab open.")
        XCTAssertEqual(contents(of: "notes.txt", in: repository), "first line\n", "Cancel must not save.")
    }
}
