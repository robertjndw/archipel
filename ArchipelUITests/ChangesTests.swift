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
        // The UI test build keeps its trash in the sandbox. Finding the file there shows both that
        // it was moved and not deleted, and that it did not go to the real Trash.
        let trashed = sandbox.support.appending(path: "Trash/draft.txt")
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "not ready yet\n")
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

    func testAnIndexEmptiedBehindTheAppIsOnlyCommittedWholeOnRequest() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("notes.txt", "first line\nsecond line\n")
        try repository.git("add", "notes.txt")
        try repository.write("draft.txt", "not ready yet\n")
        try launch(with: repository.workspace())
        showChanges()
        assertExists(stagedChange("notes.txt"), "A file staged outside the app should be listed as staged.")

        commitMessageField.click()
        app.typeText("only the staged file")
        waitUntil("the button commits what is staged") { self.commitButton.label == "Commit" && self.commitButton.isEnabled }

        // What an agent's own `git reset` does. Whether a click right now still sees the old list
        // depends on the 3 second poll, so this waits for the list instead and checks that the
        // untracked file is never committed without the button saying so first.
        try repository.git("reset", "-q")
        waitUntil("the button offers to commit everything") { self.commitButton.label == "Commit All" }
        XCTAssertEqual(try repository.git("rev-list", "--count", "HEAD"), "1", "Nothing may be committed before Commit All is chosen.")
        XCTAssertEqual(try repository.git("status", "--porcelain").split(separator: "\n").sorted(), ["?? draft.txt", "M notes.txt"])

        waitUntil("Commit All is enabled") { self.commitButton.isEnabled }
        commitButton.click()
        waitUntil("the commit exists") { try repository.git("log", "-1", "--format=%s") == "only the staged file" }
        XCTAssertEqual(try repository.git("show", "--name-only", "--format=", "HEAD").split(separator: "\n").sorted(), ["draft.txt", "notes.txt"])
    }

    func testStageAllLeavesConflictedFilesUnstaged() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.git("switch", "--quiet", "-c", "other")
        try repository.commit("notes.txt", "first line\nfrom other\n", message: "change on other")
        try repository.git("switch", "--quiet", "main")
        try repository.commit("notes.txt", "first line\nfrom main\n", message: "change on main")
        XCTAssertThrowsError(try repository.git("merge", "other"), "The fixture needs a merge that stops on a conflict.")
        try repository.write("README.md", "# edited during the merge\n")
        try repository.write("draft.txt", "new during the merge\n")
        try launch(with: repository.workspace())
        showChanges()
        assertExists(unstagedChange("notes.txt"), "The conflicted file should be listed.")
        assertExists(unstagedChange("draft.txt"), "The untracked file should be listed.")

        let stageAll = mainWindow.buttons.matching(NSPredicate(format: "label == %@", "Stage All")).element(boundBy: 0)
        assertExists(stageAll, "The Changes section should offer Stage All.")
        stageAll.click()

        // Staging a conflicted file marks it resolved with its markers still in it.
        waitUntil("everything but the conflict is staged") {
            try repository.git("status", "--porcelain").split(separator: "\n").sorted() == ["A  draft.txt", "M  README.md", "UU notes.txt"]
        }
        assertExists(stagedChange("README.md"), "The edited file should move to the staged section.")
        assertExists(stagedChange("draft.txt"), "The new file should move to the staged section.")
        XCTAssertTrue(unstagedChange("notes.txt").exists, "The conflicted file should stay unstaged.")
        XCTAssertFalse(stagedChange("notes.txt").exists, "The conflicted file must not be staged.")

        commitMessageField.click()
        app.typeText("merge other")
        XCTAssertFalse(commitButton.isEnabled, "A commit has to wait until the conflict is resolved.")
    }

    func testANestedRepositoryIsListedWithoutDiscardAndLeftOutOfDiscardAll() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        // A repository of its own inside the worktree, the way an agent's scratch clone ends up.
        let nested = FixtureRepository(url: repository.url.appending(path: "nested", directoryHint: .isDirectory), home: sandbox.home)
        try FileManager.default.createDirectory(at: nested.url, withIntermediateDirectories: true)
        try nested.git("init", "--initial-branch=main")
        try nested.git("config", "user.name", "Archipel Tests")
        try nested.git("config", "user.email", "tests@archipel.invalid")
        try nested.git("config", "commit.gpgsign", "false")
        try nested.commit("inner.txt", "inside the nested repository\n", message: "nested commit")
        try repository.write("notes.txt", "first line\nsecond line\n")
        try repository.write("README.md", "# edited\n")
        try launch(with: repository.workspace())
        showChanges()

        assertExists(unstagedChange("nested"), "The nested repository should be listed as one folder row.")
        assertExists(unstagedChange("notes.txt"), "The modified file should be listed.")
        XCTAssertFalse(unstagedChange("inner.txt").exists, "The nested repository's own files are not changes of this one.")

        unstagedChange("nested").rightClick()
        XCTAssertNotNil(shownMenuItem("Stage Changes"), "The folder row should have its menu.")
        XCTAssertFalse(menuShows("Discard Changes…"), "A nested repository is not one change to discard.")
        app.typeKey(.escape, modifierFlags: [])

        let discardAll = mainWindow.buttons.matching(NSPredicate(format: "label == %@", "Discard All Changes")).element(boundBy: 0)
        assertExists(discardAll, "The Changes section should offer Discard All.")
        discardAll.click()
        // Three rows, but only the two files count.
        let question = staticText(containing: "Discard all 2 unstaged changes?")
        assertExists(question, "Discard All should count the two files and leave the folder out.")
        dialogButton("Cancel").click()
        assertGone(question, "Cancel should close the question.")

        XCTAssertEqual(try repository.contents(of: "notes.txt"), "first line\nsecond line\n", "Cancel must discard nothing.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.url.appending(path: "inner.txt").path))
    }

    // Only the question: confirming would move the file to the Trash, and FileManager.trashItem
    // uses the Trash of the user running the tests, whatever HOME the app was given.
    func testDiscardingAStagedNewFileSaysItGoesToTheTrash() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("fresh.txt", "never committed\n")
        try repository.git("add", "fresh.txt")
        try launch(with: repository.workspace())
        showChanges()
        assertExists(stagedChange("fresh.txt"), "The staged new file should be listed.")

        stagedChange("fresh.txt").rightClick()
        chooseContextMenu("Discard Changes…")
        assertExists(staticText(containing: "Discard changes to fresh.txt?"), "Discarding should ask first.")
        let explanation = staticText(containing: "It will be removed from the index and moved to the Trash.")
        assertExists(explanation, "The question should say the file is never committed and where it goes.")
        dialogButton("Cancel").click()
        assertGone(explanation, "Cancel should close the question.")

        XCTAssertEqual(try repository.git("diff", "--cached", "--name-only"), "fresh.txt", "Cancel must leave the file staged.")
        XCTAssertEqual(try repository.contents(of: "fresh.txt"), "never committed\n")
    }

    func testACommitInProgressSurvivesSwitchingWorktreesAndReportsItsFailure() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        // Holds the commit until the test lets go, then refuses it, as a slow lint hook would.
        let started = sandbox.root.appending(path: "hook-started")
        let release = sandbox.root.appending(path: "hook-release")
        let hook = repository.url.appending(path: ".git/hooks/pre-commit")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            #!/bin/sh
            touch '\(started.path)'
            i=0
            while [ ! -e '\(release.path)' ] && [ $i -lt 1200 ]; do sleep 0.1; i=$((i+1)); done
            echo "the lint hook refused the commit" >&2
            exit 1

            """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try repository.write("notes.txt", "first line\nsecond line\n")
        try repository.git("add", "notes.txt")
        try launch(with: repository.workspace(linkedWorktrees: [feature]))
        showChanges()
        assertExists(stagedChange("notes.txt"), "A file staged outside the app should be listed as staged.")

        commitMessageField.click()
        app.typeText("held by the hook")
        waitUntil("the commit button is enabled") { self.commitButton.isEnabled }
        commitButton.click()
        waitUntil("the hook is running") { FileManager.default.fileExists(atPath: started.path) }

        sidebarWorktree("feature").click()
        assertExists(mainWindow(titled: "fixture - feature"), "The feature worktree should be selected.")
        sidebarWorktree("main").click()
        assertExists(mainWindow(titled: "fixture - main"), "The main checkout should be selected again.")

        // The message tells this panel from the feature worktree's, whose field is empty.
        waitUntil("the panel shows the commit's message again") { self.commitMessageField.value as? String == "held by the hook" }
        XCTAssertFalse(commitMessageField.isEnabled, "The message cannot change while its commit runs.")
        XCTAssertFalse(commitButton.isEnabled, "The commit that is running must not be started a second time.")

        try Data().write(to: release)
        assertExists(staticText(containing: "the lint hook refused the commit"), "The hook's refusal should be shown after coming back.")
        waitUntil("the button can be used again") { self.commitButton.isEnabled }
        XCTAssertEqual(try repository.git("rev-list", "--count", "HEAD"), "1", "A refused commit must not exist.")
        XCTAssertEqual(try repository.git("diff", "--cached", "--name-only"), "notes.txt", "The staged file should stay staged.")
    }
}
