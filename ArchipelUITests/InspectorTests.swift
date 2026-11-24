import ArchipelCore
import XCTest

final class InspectorTests: ArchipelUITestCase {
    func testChangesFollowTheDiskAndAStagedFileIsCommitted() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())
        showChanges()
        XCTAssertFalse(unstagedChange("notes.txt").exists, "A clean checkout has no changes to list.")

        // Changed behind the app's back, the way an agent or an editor would.
        try repository.write("notes.txt", "first line\nsecond line\n")
        try repository.write("draft.txt", "not ready yet\n")
        assertExists(unstagedChange("notes.txt"), "The modified file should show up by itself.")
        assertExists(unstagedChange("draft.txt"), "The new file should show up by itself.")

        // Through the row's menu: its hover buttons are folded into the row for accessibility and
        // cannot be told apart from outside.
        unstagedChange("notes.txt").rightClick()
        chooseContextMenu("Stage Changes")
        assertExists(stagedChange("notes.txt"), "The file should move to the staged section.")
        waitUntil("git has the file staged") { try repository.git("diff", "--cached", "--name-only") == "notes.txt" }

        commitMessageField.click()
        app.typeText("add a second line")
        XCTAssertEqual(commitButton.label, "Commit", "With something staged the button commits only that.")
        waitUntil("the commit button is enabled") { self.commitButton.isEnabled }
        commitButton.click()

        waitUntil("the commit exists") { try repository.git("log", "-1", "--format=%s") == "add a second line" }
        XCTAssertEqual(try repository.git("show", "--name-only", "--format=", "HEAD"), "notes.txt")
        XCTAssertEqual(try repository.git("rev-list", "--count", "HEAD"), "2")
        // The unstaged file was left out of the commit and is still listed.
        XCTAssertEqual(try repository.git("status", "--porcelain"), "?? draft.txt")
        assertGone(stagedChange("notes.txt"), "The committed file should leave the list.")
        assertExists(unstagedChange("draft.txt"), "The file that was not staged should still be listed.")
    }

    func testCommitAllStagesEverything() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("notes.txt", "first line\nsecond line\n")
        try repository.write("draft.txt", "ready\n")
        try launch(with: repository.workspace())

        // Commit… is the keyboard's way in: it reveals the Changes tab with the cursor in the field.
        chooseMenu("Project", "Commit…")
        assertExists(unstagedChange("notes.txt"), "The modified file should be listed.")
        assertExists(unstagedChange("draft.txt"), "The untracked file should be listed.")
        XCTAssertFalse(commitButton.isEnabled, "There is nothing to commit without a message.")
        commitMessageField.click()
        app.typeText("commit everything")
        XCTAssertEqual(commitButton.label, "Commit All", "With nothing staged the button offers to commit everything.")
        waitUntil("the commit button is enabled") { self.commitButton.isEnabled }
        commitButton.click()

        waitUntil("the commit exists") { try repository.git("log", "-1", "--format=%s") == "commit everything" }
        XCTAssertEqual(try repository.git("status", "--porcelain"), "")
        XCTAssertEqual(try repository.git("show", "--name-only", "--format=", "HEAD").split(separator: "\n").sorted(), ["draft.txt", "notes.txt"])
        assertGone(unstagedChange("notes.txt"), "Nothing should be left to list.")
    }

    func testOpeningAFileAndADiffFromTheInspector() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("notes.txt", "first line\nsecond line\n")
        try launch(with: repository.workspace())

        chooseMenu("View", "Show Files")
        let file = mainWindow.staticTexts.matching(identifier: "README.md").element(boundBy: 0)
        assertExists(file, "The Files tab should list the worktree's files.")
        file.doubleClick()
        assertExists(tab("README.md"), "Opening a file should give it a tab.")

        showChanges()
        assertExists(unstagedChange("notes.txt"), "The modified file should be listed.")
        unstagedChange("notes.txt").doubleClick()
        assertExists(tab("notes.txt"), "Opening a change should give its diff a tab.")
        assertExists(mainWindow.radioButtons["Side by Side"], "The tab should show the diff viewer.")
        waitUntil("both tabs are saved") {
            try sandbox.savedWorkspace().allWorktrees[0].panes.flatMap(\.tabs).count == 2
        }
    }

    func testOpeningADiffInTheEditorAndSavingAnEdit() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("notes.txt", "first line\nsecond line\n")
        try launch(with: repository.workspace())

        showChanges()
        unstagedChange("notes.txt").doubleClick()
        assertExists(mainWindow.radioButtons["Side by Side"], "The change should open in the diff viewer.")

        mainWindow.buttons["Open in Editor"].click()
        // By identifier: a terminal is a text view to accessibility as well.
        let editor = mainWindow.textViews.matching(identifier: "editor.text").element(boundBy: 0)
        assertExists(editor, "Open in Editor should show the file in the editor.")
        // Opens next to the diff instead of replacing it, and not as a preview tab.
        waitUntil("the diff and the file are both saved as tabs") {
            let tabs = try sandbox.savedWorkspace().allWorktrees[0].panes.flatMap(\.tabs)
            let keptFile = tabs.contains {
                guard case .file(let url) = $0.content else { return false }
                return url.lastPathComponent == "notes.txt" && !$0.isPreview
            }
            return keptFile && tabs.contains { $0.content == .diff(path: "notes.txt", staged: false) }
        }

        // The diff is read-only, so the edit has to go through the editor tab.
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("third line")
        chooseMenu("File", "Save")
        waitUntil("the edit is on disk") {
            try repository.contents(of: "notes.txt").hasPrefix("first line\nsecond line\nthird line")
        }
    }

    func testADiffOverTheSizeLimitSaysSoUntilTheFileShrinks() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.commit("big.txt", "small\n", message: "add big.txt")
        // Over the diff viewer's 5 MB, in short lines so it is plainly text.
        let line = String(repeating: "0123456789", count: 10) + "\n"
        try repository.write("big.txt", String(repeating: line, count: 60_000))
        try launch(with: repository.workspace())

        showChanges()
        assertExists(unstagedChange("big.txt"), "The grown file should be listed.")
        unstagedChange("big.txt").doubleClick()
        assertExists(tab("big.txt"), "Opening a change should give its diff a tab.")
        let tooLarge = mainWindow.staticTexts["File Too Large"]
        assertExists(tooLarge, "A diff over the limit should say so instead of loading it.")
        XCTAssertFalse(mainWindow.radioButtons["Side by Side"].exists, "There is no comparison to present.")

        try repository.write("big.txt", "small\nand a little more\n")
        assertExists(mainWindow.radioButtons["Side by Side"], "Back under the limit, the diff should be shown again.")
        assertGone(tooLarge, "The size warning should go once the file is small again.")

        try repository.git("checkout", "--", "big.txt")
        assertExists(staticText(containing: "This file matches the staged version."), "A restored file has nothing left to compare.")
    }

    func testHidingAndShowingTheInspector() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        let filesTab = mainWindow.buttons.matching(identifier: "Files").element(boundBy: 0)
        assertExists(filesTab, "The inspector is shown by default.")
        chooseMenu("View", "Hide Inspector")
        assertGone(filesTab, "Hide Inspector should close it.")
        chooseMenu("View", "Show Changes")
        assertExists(commitMessageField, "Show Changes should bring the inspector back on that tab.")
    }
}
