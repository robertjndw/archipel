import ArchipelCore
import XCTest

final class WorktreeTests: ArchipelUITestCase {
    private func openAddWorktreeSheet() {
        chooseMenu("Project", "Add Worktree…")
        assertExists(branchField, "The Add Worktree sheet did not come up.")
    }

    func testCreatingAWorktreeOnANewBranch() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        openAddWorktreeSheet()
        app.typeText("feature-login")
        assertExists(sheet.buttons["Create Branch “feature-login”"], "Typing an unknown name should offer to create that branch.")
        let create = sheet.buttons["Create"]
        waitUntil("the name has been checked") { create.isEnabled }
        create.click()

        assertGone(sheet, "The sheet should close once the worktree exists.")
        assertExists(sidebarWorktree("feature-login"), "The new worktree should be in the sidebar.")
        assertExists(mainWindow(titled: "fixture - feature-login"),
                     "The new worktree should be selected.")

        // New worktrees go under the configured root, one folder per project.
        let expected = sandbox.worktreesRoot.appending(path: "fixture/feature-login").path
        XCTAssertEqual(try repository.worktreePaths, [repository.url.path, expected])
        XCTAssertTrue(try repository.branches.contains("feature-login"))
        XCTAssertEqual(try repository.git(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: expected)), "feature-login")
        waitUntil("the worktree is saved") {
            try sandbox.savedWorkspace().allWorktrees.map(\.path.path) == [repository.url.path, expected]
        }
    }

    func testAnInvalidBranchNameCannotBeCreated() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        openAddWorktreeSheet()
        // Two dots in a row are not allowed in a ref name.
        app.typeText("bad..name")
        assertExists(sheet.buttons["Not a valid branch name"], "The create row should say the name is invalid.")
        XCTAssertFalse(sheet.buttons["Create"].isEnabled, "An invalid name must not be creatable.")
        // Return is the default action and has to be refused as well.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet.exists, "Return on an invalid name should leave the sheet open.")

        // Fixing the name makes the same sheet usable again.
        replaceText(with: "good-name")
        assertExists(sheet.buttons["Create Branch “good-name”"], "The create row should follow the field.")
        waitUntil("the corrected name is accepted") { self.sheet.buttons["Create"].isEnabled }
        sheet.buttons["Cancel"].click()
        assertGone(sheet, "Cancel should close the sheet.")

        XCTAssertEqual(try repository.branches, ["main"])
        XCTAssertEqual(try repository.worktreePaths, [repository.url.path])
        XCTAssertEqual(sidebarWorktrees.count, 1)
    }

    func testAddingAWorktreeForAnExistingBranch() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.git("branch", "release")
        try launch(with: repository.workspace())

        openAddWorktreeSheet()
        app.typeText("release")
        let add = sheet.buttons["Add"]
        assertExists(add, "An exact match should be added, not created.")
        add.click()

        assertGone(sheet, "The sheet should close once the worktree exists.")
        assertExists(sidebarWorktree("release"), "The worktree should be in the sidebar.")
        let expected = sandbox.worktreesRoot.appending(path: "fixture/release").path
        XCTAssertEqual(try repository.worktreePaths, [repository.url.path, expected])
        XCTAssertEqual(try repository.branches.sorted(), ["main", "release"])
    }

    func testABranchHeldByADeletedWorktreeIsOnlyReleasedWhenConfirmed() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        // Made outside the app and deleted by hand: git still has it registered, with its branch.
        let elsewhere = sandbox.worktreesRoot.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let stale = try repository.addWorktree(branch: "feature", in: elsewhere)
        try FileManager.default.removeItem(at: stale.path)
        try launch(with: repository.workspace())

        openAddWorktreeSheet()
        app.typeText("feature")
        let add = sheet.buttons["Add"]
        assertExists(add, "An exact match should be added, not created.")
        add.click()

        // A moved folder looks the same as a deleted one, and dropping its registration would
        // break it, so nothing is dropped before the user has said which it is.
        let release = app.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", "Release Branch", "Release Branch")).element(boundBy: 0)
        assertExists(release, "Using a branch held by a missing worktree should ask first.")
        XCTAssertEqual(try repository.worktreePaths.count, 2, "Nothing may be dropped before the answer.")
        release.click()

        assertGone(sheet, "The sheet should close once the worktree exists.")
        assertExists(sidebarWorktree("feature"), "The worktree should be in the sidebar.")
        let expected = sandbox.worktreesRoot.appending(path: "fixture/feature").path
        waitUntil("the branch moved to the new worktree") { try repository.worktreePaths == [repository.url.path, expected] }
    }

    func testRemovingAWorktreeKeepsItsFolderUnlessAsked() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        sidebarWorktree("feature").click()
        chooseMenu("Project", "Remove Worktree…")
        assertExists(sheet.buttons["Remove"], "Removing a worktree should ask first.")
        sheet.buttons["Remove"].click()

        assertGone(sidebarWorktree("feature"), "The worktree should leave the sidebar.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: feature.path.path), "The folder was not asked to be deleted.")
        XCTAssertEqual(try repository.worktreePaths, [repository.url.path, feature.path.path])
        XCTAssertTrue(try repository.branches.contains("feature"))
    }

    func testRemovingAWorktreeWithItsFolderAndBranch() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        sidebarWorktree("feature").click()
        chooseMenu("Project", "Remove Worktree…")
        let deleteFolder = sheet.switches.element(boundBy: 0)
        let deleteBranch = sheet.switches.element(boundBy: 1)
        assertExists(deleteFolder, "The sheet should offer to delete the folder.")
        XCTAssertFalse(deleteBranch.isEnabled, "The branch can only go together with the folder.")
        deleteFolder.click()
        waitUntil("the branch switch is enabled") { deleteBranch.isEnabled }
        deleteBranch.click()
        let delete = sheet.buttons["Delete"]
        assertExists(delete, "With the folder checked the button should say Delete.")
        delete.click()

        assertGone(sidebarWorktree("feature"), "The worktree should leave the sidebar.")
        waitUntil("git has forgotten the worktree and its branch") {
            try repository.worktreePaths == [repository.url.path] && repository.branches == ["main"]
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: feature.path.path), "The folder should be gone from disk.")
        // The main checkout takes the selection over.
        assertExists(mainWindow(titled: "fixture - main"),
                     "The main checkout should be selected after the removal.")
    }

    func testAWorktreeMadeOutsideTheAppIsSuggested() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        // In git's list, but not in the workspace the app starts with.
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace())

        let suggestion = mainWindow.buttons["1 more worktree on disk"]
        assertExists(suggestion, "A worktree git knows about should be offered under its project.")
        XCTAssertFalse(sidebarWorktree("feature").exists, "A suggestion is not in the sidebar until it is accepted.")
        suggestion.click()
        let add = app.popovers.buttons["Add"]
        assertExists(add, "The suggestion should open its list.")
        add.click()

        assertExists(sidebarWorktree("feature"), "The accepted worktree should be in the sidebar.")
        assertGone(suggestion, "Nothing is left to suggest.")
        waitUntil("the worktree is saved") {
            try sandbox.savedWorkspace().allWorktrees.map(\.path.path) == [repository.url.path, feature.path.path]
        }
    }

    func testRemovingAWorktreeWhoseFolderIsGone() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        // Deleted by hand, so git still has it registered and its branch counts as checked out.
        try FileManager.default.removeItem(at: feature.path)
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        assertExists(mainWindow.staticTexts["Folder missing"], "A worktree without its folder should say so.")
        sidebarWorktree("feature").click()
        chooseMenu("Project", "Remove Worktree…")
        assertExists(sheet.buttons["Remove"], "Removing a worktree should ask first.")
        XCTAssertEqual(sheet.switches.count, 0, "With the folder gone there is nothing to offer to delete.")
        sheet.buttons["Remove"].click()

        assertGone(sidebarWorktree("feature"), "The worktree should leave the sidebar.")
        waitUntil("git has dropped the leftover registration") { try repository.worktreePaths == [repository.url.path] }
        // The branch was not asked to be deleted, and is free to be checked out again.
        XCTAssertEqual(try repository.branches.sorted(), ["feature", "main"])
    }

    func testThePrimaryCheckoutCannotBeRemoved() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        app.menuBars.menuBarItems["Project"].click()
        XCTAssertFalse(menuItem("Project", "Remove Worktree…").isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSwitchingTheBranchOfAWorktree() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.git("branch", "release")
        try launch(with: repository.workspace())

        chooseMenu("Project", "Switch Branch…")
        assertExists(branchField, "The Switch Branch sheet did not come up.")
        app.typeText("release")
        let confirm = sheet.buttons["Switch"]
        waitUntil("the branch can be switched to") { confirm.isEnabled }
        confirm.click()

        assertGone(sheet, "The sheet should close after the switch.")
        waitUntil("the repository is on the new branch") { try repository.currentBranch == "release" }
        assertExists(sidebarWorktree("release"), "The sidebar should show the branch that is checked out now.")
        waitUntil("the new branch is saved") { try sandbox.savedWorkspace().allWorktrees.map(\.branch) == ["release"] }
    }
}
