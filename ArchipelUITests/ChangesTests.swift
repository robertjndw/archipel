import ArchipelCore
import XCTest

final class ChangesTests: ArchipelUITestCase {
    /// Opens the Switch Branch sheet from the branch name in the Changes header, the way a person
    /// would, and not through the menu.
    private func openSwitchBranchSheet(from branch: String) {
        let title = mainWindow.buttons.matching(NSPredicate(format: "label CONTAINS %@", branch)).element(boundBy: 0)
        assertExists(title, "The Changes header should show the branch as a button.")
        title.click()
        assertExists(branchField, "Clicking the branch name should open the Switch Branch sheet.")
    }

    /// The confirmation of a discard is a dialog attached to the window, with the one destructive
    /// button. Its title is the same as the hover button's, so it is found by label and not by
    /// being a hittable sheet.
    private func confirmDiscard() {
        let discard = app.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", "Discard", "Discard")).element(boundBy: 0)
        assertExists(discard, "Discarding should ask for confirmation first.")
        discard.click()
    }

    func testUnstagingAFileMovesItBack() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("notes.txt", "first line\nsecond line\n")
        try repository.git("add", "notes.txt")
        try launch(with: repository.workspace())
        showChanges()
        assertExists(stagedChange("notes.txt"), "A file staged outside the app should be listed as staged.")

        stagedChange("notes.txt").rightClick()
        chooseContextMenu("Unstage Changes")

        assertExists(unstagedChange("notes.txt"), "The file should move back to the unstaged section.")
        assertGone(stagedChange("notes.txt"), "The file should leave the staged section.")
        waitUntil("git has nothing staged") { try repository.git("diff", "--cached", "--name-only") == "" }
        // Unstaging keeps the edit on disk.
        XCTAssertEqual(try repository.git("status", "--porcelain"), "M notes.txt")
    }

    func testDiscardingAModifiedFileRestoresItsCommittedContent() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("notes.txt", "first line\nsecond line\n")
        try repository.write("README.md", "# edited\n")
        try launch(with: repository.workspace())
        showChanges()
        assertExists(unstagedChange("notes.txt"), "The modified file should be listed.")

        unstagedChange("notes.txt").rightClick()
        chooseContextMenu("Discard Changes…")
        // Nothing may be lost before the answer.
        XCTAssertEqual(try String(contentsOf: repository.url.appending(path: "notes.txt"), encoding: .utf8), "first line\nsecond line\n",
                       "Nothing may be discarded before the answer.")
        confirmDiscard()

        assertGone(unstagedChange("notes.txt"), "The discarded file should leave the list.")
        XCTAssertEqual(try String(contentsOf: repository.url.appending(path: "notes.txt"), encoding: .utf8), "first line\n")
        // Only the file that was asked about is touched.
        XCTAssertEqual(try repository.git("status", "--porcelain"), "M README.md")
        assertExists(unstagedChange("README.md"), "The other change should still be listed.")
    }

    func testDiscardingAnUntrackedFileRemovesIt() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("draft.txt", "not ready yet\n")
        try launch(with: repository.workspace())
        showChanges()
        assertExists(unstagedChange("draft.txt"), "The new file should be listed.")

        unstagedChange("draft.txt").rightClick()
        chooseContextMenu("Discard Changes…")
        confirmDiscard()

        assertGone(unstagedChange("draft.txt"), "The discarded file should leave the list.")
        // Moved to the Trash, so it is gone from the checkout.
        waitUntil("the file is gone from the checkout") {
            !FileManager.default.fileExists(atPath: repository.url.appending(path: "draft.txt").path)
        }
        XCTAssertEqual(try repository.git("status", "--porcelain"), "")
    }

    func testCancellingASwitchLeavesTheBranchAlone() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.git("branch", "release")
        try launch(with: repository.workspace())
        showChanges()

        openSwitchBranchSheet(from: "main")
        app.typeText("release")
        assertExists(sheet.buttons["Switch"], "An existing branch should be switched to, not created.")
        sheet.buttons["Cancel"].click()

        assertGone(sheet, "Cancel should close the sheet.")
        XCTAssertEqual(try repository.currentBranch, "main")
    }

    func testSwitchingBranchTakesUncommittedChangesAlong() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.git("branch", "release")
        try repository.write("notes.txt", "first line\nsecond line\n")
        try repository.write("draft.txt", "not ready yet\n")
        try launch(with: repository.workspace())
        showChanges()
        assertExists(unstagedChange("notes.txt"), "The modified file should be listed before the switch.")

        openSwitchBranchSheet(from: "main")
        app.typeText("release")
        let switchButton = sheet.buttons["Switch"]
        assertExists(switchButton, "An exact match should be switched to, not created.")
        switchButton.click()

        assertGone(sheet, "The sheet should close once the branch is checked out.")
        waitUntil("release is checked out") { try repository.currentBranch == "release" }
        XCTAssertEqual(try String(contentsOf: repository.url.appending(path: "notes.txt"), encoding: .utf8), "first line\nsecond line\n",
                       "The edit should come along to the new branch.")
        XCTAssertEqual(try String(contentsOf: repository.url.appending(path: "draft.txt"), encoding: .utf8), "not ready yet\n")
        XCTAssertEqual(try repository.git("status", "--porcelain").split(separator: "\n").sorted(), ["?? draft.txt", "M notes.txt"])
        assertExists(unstagedChange("notes.txt"), "The changes should still be listed on the new branch.")
        waitUntil("the new branch is saved") {
            try sandbox.savedWorkspace().allWorktrees[0].branch == "release"
        }
    }

    func testCreatingABranchFromTheSwitchBranchSheet() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())
        showChanges()

        openSwitchBranchSheet(from: "main")
        app.typeText("feature-login")
        assertExists(sheet.buttons["Create Branch “feature-login”"], "Typing an unknown name should offer to create that branch.")
        let create = sheet.buttons["Create and Switch"]
        waitUntil("the name has been checked") { create.isEnabled }
        create.click()

        assertGone(sheet, "The sheet should close once the branch is checked out.")
        waitUntil("the new branch is checked out") { try repository.currentBranch == "feature-login" }
        XCTAssertEqual(try repository.branches.sorted(), ["feature-login", "main"])
        // Still the main checkout: no second worktree was made.
        XCTAssertEqual(try repository.worktreePaths, [repository.url.path])
        waitUntil("the new branch is saved") {
            try sandbox.savedWorkspace().allWorktrees[0].branch == "feature-login"
        }
    }
}
