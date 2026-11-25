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

    /// By identifier: a terminal is a text view to accessibility as well.
    private var editor: XCUIElement { mainWindow.textViews.matching(identifier: "editor.text").element(boundBy: 0) }

    /// Like `openQuickly`, for a file that may not open as text.
    private func openQuicklyWithoutText(_ fileName: String) {
        app.typeKey("p", modifierFlags: .command)
        assertExists(paletteField, "Open Quickly did not come up.")
        app.typeText(fileName)
        let row = paletteRow(startingWith: fileName)
        assertExists(row, "Open Quickly should list \(fileName).")
        row.click()
        assertExists(tab(fileName), "Opening a file should give it a tab.")
    }

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

    func testMarkdownPreviewRendersFollowsLinksAndReloads() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("README.md", "# Rendered Title\n\nSee the [notes file](notes.txt).\n")
        try launch(with: repository.workspace())

        openQuickly("README.md")
        let presentation = mainWindow.radioGroups["editor.markdownPresentation"]
        assertExists(presentation, "A Markdown file should offer source and preview.")
        let webView = mainWindow.webViews.firstMatch
        XCTAssertFalse(webView.exists, "Markdown opens as source.")

        presentation.radioButtons["Preview"].click()
        assertExists(webView.staticTexts["Rendered Title"], "The preview should render the heading.")
        assertGone(editor, "The preview replaces the text view.")

        // Relative links open the file in the app rather than navigating the preview away.
        webView.links["notes file"].click()
        assertExists(tab("notes.txt"), "A relative link should open the file as a tab.")

        // The choice belongs to the file, so coming back finds the preview again.
        tab("README.md").click()
        assertExists(webView.staticTexts["Rendered Title"], "Switching back should keep the preview.")

        // Agents edit the file on disk, so that is what the open preview has to pick up.
        try repository.write("README.md", "# Changed on Disk\n")
        assertExists(webView.staticTexts["Changed on Disk"], "The preview should follow the file on disk.")

        presentation.radioButtons["Source"].click()
        assertExists(editor, "Source brings the text view back.")
        waitUntil("the source shows the file as it is now") { (self.editor.value as? String)?.contains("# Changed on Disk") == true }
    }

    func testAFileWithAVeryLongLineIsNotLoadedAsText() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        // One line over the editor's 50,000 characters, the shape of a minified bundle.
        try repository.commit("bundle.min.txt", String(repeating: "x", count: 60_000) + "\n", message: "add a minified file")
        try launch(with: repository.workspace())

        openQuicklyWithoutText("bundle.min.txt")
        assertExists(mainWindow.staticTexts["Lines Too Long"], "A file with a very long line should say why it is not shown.")
        // Not clicked: it would open the file in whatever app this machine has for it.
        XCTAssertTrue(mainWindow.buttons["Open in Default App"].exists, "The file should be offered to its default app instead.")
        XCTAssertFalse(editor.exists, "The text should not be loaded into the editor.")
    }

    func testMarkdownPreviewIgnoresActiveContentAndAsksBeforeLeaving() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("README.md", """
            # Hardened Title

            Plain paragraph text.

            <script>document.body.innerHTML = "<h1>Scripted</h1>";</script>
            <p onmouseover="document.body.innerHTML = 'Hovered'">Hover text</p>
            <meta http-equiv="refresh" content="0; url=https://example.com/">
            <form action="https://example.com/"><input name="q"><button>Send</button></form>

            [custom link](x-archipel-test://go)

            [outside link](../outside.txt)

            """)
        // Next to the repository, so the link leads out of the worktree to a file that exists.
        try "outside\n".write(to: sandbox.root.appending(path: "outside.txt"), atomically: true, encoding: .utf8)
        try launch(with: repository.workspace())

        openQuickly("README.md")
        mainWindow.radioGroups["editor.markdownPresentation"].radioButtons["Preview"].click()
        let webView = mainWindow.webViews.element(boundBy: 0)
        assertExists(webView.staticTexts["Hardened Title"], "The preview should render the heading.")
        assertExists(webView.staticTexts["Hover text"], "Text around raw HTML should still render.")
        XCTAssertFalse(webView.staticTexts["Scripted"].exists, "A script in the Markdown must not run.")
        let tabCount = tabs.count

        // No app is registered for this scheme, so the alert explains that instead of offering
        // Open. Either way it has to name where the link goes.
        webView.links["custom link"].click()
        let destination = staticText(containing: "x-archipel-test://go")
        assertExists(destination, "A link with another scheme should name its destination before anything opens.")
        let cancel = dialogButton("Cancel")
        if cancel.exists { cancel.click() } else { dialogButton("OK").click() }
        assertGone(destination, "The alert should close.")

        webView.links["outside link"].click()
        let question = staticText(containing: "Open a file outside this worktree?")
        assertExists(question, "A link out of the worktree should ask first.")
        dialogButton("Cancel").click()
        assertGone(question, "Cancel should close the question.")
        XCTAssertFalse(tab("outside.txt").exists, "Cancel must not open the file.")
        XCTAssertEqual(tabs.count, tabCount, "Neither link may open a tab without being agreed to.")

        // The meta refresh and the form had all this time to take the preview somewhere else.
        XCTAssertTrue(webView.staticTexts["Hardened Title"].exists, "The preview should still show the README.")
        XCTAssertTrue(webView.staticTexts["Plain paragraph text."].exists, "The preview should still show the README.")
    }

    func testTabIndentsEverySelectedLineAsOneUndoStep() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        // No indented lines, so the editor indents with a tab.
        try repository.commit("lines.txt", "alpha\nbeta\ngamma\n", message: "add lines")
        try launch(with: repository.workspace())

        openQuickly("lines.txt")
        editor.click()
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeKey(.downArrow, modifierFlags: .shift)
        app.typeKey(.downArrow, modifierFlags: .shift)
        app.typeKey(.tab, modifierFlags: [])
        waitUntil("the two selected lines are indented") { self.editor.value as? String == "\talpha\n\tbeta\ngamma\n" }

        undo()
        waitUntil("one undo takes the indent back") { self.editor.value as? String == "alpha\nbeta\ngamma\n" }
        XCTAssertEqual(contents(of: "lines.txt", in: repository), "alpha\nbeta\ngamma\n", "Nothing was saved.")
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
