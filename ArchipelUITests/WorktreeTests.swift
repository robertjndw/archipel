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

    func testUndoingTheRemovalOfAWorktreeWhoseFolderWasKept() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        sidebarWorktree("feature").click()
        chooseMenu("Project", "Remove Worktree…")
        assertExists(sheet.buttons["Remove"], "Removing a worktree should ask first.")
        sheet.buttons["Remove"].click()
        assertGone(sidebarWorktree("feature"), "The worktree should leave the sidebar.")

        undo()
        assertExists(sidebarWorktree("feature"), "Undo should put the worktree back in the sidebar.")
        waitUntil("the worktree is saved again") {
            try sandbox.savedWorkspace().allWorktrees.map(\.path.path) == [repository.url.path, feature.path.path]
        }
        // It is in the sidebar again, so offering it as a folder on disk would list it twice.
        XCTAssertFalse(mainWindow.buttons["1 more worktree on disk"].exists)

        redo()
        assertGone(sidebarWorktree("feature"), "Redo should remove it again.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: feature.path.path), "Redo must keep the folder as well.")
        XCTAssertEqual(try repository.worktreePaths, [repository.url.path, feature.path.path])
    }

    func testRemovingAWorktreeWithItsFolderCannotBeUndone() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        sidebarWorktree("feature").click()
        chooseMenu("Project", "Remove Worktree…")
        let deleteFolder = sheet.switches.element(boundBy: 0)
        assertExists(deleteFolder, "The sheet should offer to delete the folder.")
        deleteFolder.click()
        sheet.buttons["Delete"].click()
        assertGone(sidebarWorktree("feature"), "The worktree should leave the sidebar.")

        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertFalse(menuItem("Edit", "Undo").isEnabled, "A deleted folder cannot be brought back by undo.")
        app.typeKey(.escape, modifierFlags: [])
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

    func testRemovingSeveralWorktreesPickedTogether() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let first = try repository.addWorktree(branch: "first", in: sandbox.worktreesRoot)
        let second = try repository.addWorktree(branch: "second", in: sandbox.worktreesRoot)
        let third = try repository.addWorktree(branch: "third", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace(linkedWorktrees: [first, second, third]))

        sidebarWorktree("first").click()
        XCUIElement.perform(withKeyModifiers: .command) { sidebarWorktree("third").click() }
        // Picking a second row adds to the selection without switching what the window shows.
        assertExists(mainWindow(titled: "fixture - first"), "⌘-click should not change the shown worktree.")

        sidebarWorktree("third").rightClick()
        chooseContextMenu("Remove 2 Worktrees…")
        assertExists(sheet.buttons["Remove"], "Removing several worktrees should ask once.")
        let deleteFolders = sheet.switches.element(boundBy: 0)
        let deleteBranches = sheet.switches.element(boundBy: 1)
        deleteFolders.click()
        waitUntil("the branch switch is enabled") { deleteBranches.isEnabled }
        deleteBranches.click()
        sheet.buttons["Delete"].click()

        assertGone(sidebarWorktree("first"), "The first picked worktree should leave the sidebar.")
        assertGone(sidebarWorktree("third"), "The second picked worktree should leave the sidebar.")
        assertExists(sidebarWorktree("second"), "A worktree that was not picked stays.")
        waitUntil("git has forgotten both worktrees and their branches") {
            try repository.worktreePaths == [repository.url.path, second.path.path]
                && repository.branches.sorted() == ["main", "second"]
        }
    }

    func testTheProjectMenuRemovesEveryPickedWorktreeButThePrimaryCheckout() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        let other = try repository.addWorktree(branch: "other", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace(linkedWorktrees: [feature, other]))

        sidebarWorktree("main").click()
        XCUIElement.perform(withKeyModifiers: .shift) { sidebarWorktree("other").click() }
        // The primary checkout is picked too, but it cannot be removed, so only two are counted.
        chooseMenu("Project", "Remove 2 Worktrees…")
        sheet.buttons["Remove"].click()

        assertGone(sidebarWorktree("feature"), "The worktree should leave the sidebar.")
        assertGone(sidebarWorktree("other"), "The worktree should leave the sidebar.")
        assertExists(sidebarWorktree("main"), "The primary checkout stays.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: feature.path.path), "The folders were not asked to be deleted.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path.path), "The folders were not asked to be deleted.")
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

    func testAWorktreeWhoseFolderIsGoneOffersToLocateIt() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try FileManager.default.removeItem(at: feature.path)
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        assertExists(mainWindow.staticTexts["Folder missing"], "A worktree without its folder should say so.")
        sidebarWorktree("feature").rightClick()
        let locate = app.menuItems["Locate Folder…"]
        waitUntil("the context menu offers Locate Folder") { locate.isHittable }
        XCTAssertTrue(locate.isEnabled)
        let finder = app.menuItems.matching(NSPredicate(format: "title == %@", "Show in Finder"))
            .allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertEqual(finder?.isEnabled, false, "There is no folder to show.")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testLocatingAMissingWorktreeRefusesAnUnrelatedRepository() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try FileManager.default.removeItem(at: feature.path)
        let unrelated = try sandbox.makeRepository(named: "unrelated")
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        assertExists(mainWindow.staticTexts["Folder missing"], "A worktree without its folder should say so.")
        sidebarWorktree("feature").rightClick()
        chooseContextMenu("Locate Folder…")
        // The panel's confirm button carries the prompt the app gave it.
        let locate = dialogButton("Locate")
        assertExists(locate, "Locate Folder… should open a folder picker.")
        // Go to Folder, as in ProjectTests: the one way to name a folder without clicking through
        // whatever the panel shows on this machine.
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goToField = app.sheets.textFields.element(boundBy: 0)
        assertExists(goToField, "The open panel did not show its Go to Folder field.")
        app.typeText(unrelated.url.path)
        app.typeKey(.return, modifierFlags: [])
        waitUntil("the panel accepts the folder") { locate.isEnabled }
        locate.click()

        let refusal = staticText(containing: "unrelated is not a linked git worktree")
        assertExists(refusal, "A folder that is not the worktree should be refused with the reason.")
        // OK is the alert's default button.
        app.typeKey(.return, modifierFlags: [])
        assertGone(refusal, "OK should close the alert.")
        assertExists(mainWindow.staticTexts["Folder missing"], "The worktree should still be missing its folder.")
        XCTAssertEqual(try sandbox.savedWorkspace().allWorktrees.map(\.path.path), [repository.url.path, feature.path.path],
                       "The worktree must keep the folder it had.")
    }

    func testRemovingPickedWorktreesLeavesNoPickBehind() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let first = try repository.addWorktree(branch: "first", in: sandbox.worktreesRoot)
        let second = try repository.addWorktree(branch: "second", in: sandbox.worktreesRoot)
        let third = try repository.addWorktree(branch: "third", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace(linkedWorktrees: [first, second, third]))

        sidebarWorktree("main").click()
        XCUIElement.perform(withKeyModifiers: .shift) { sidebarWorktree("second").click() }
        chooseMenu("Project", "Remove 2 Worktrees…")
        assertExists(sheet.buttons["Remove"], "Removing several worktrees should ask once.")
        sheet.buttons["Remove"].click()
        assertGone(sidebarWorktree("first"), "The first picked worktree should leave the sidebar.")
        assertGone(sidebarWorktree("second"), "The second picked worktree should leave the sidebar.")

        // The primary checkout is all that is left of the pick, and one row is no batch.
        sidebarWorktree("main").rightClick()
        XCTAssertNotNil(shownMenuItem("Primary Checkout Can't Be Removed"), "The row should have its own menu back.")
        XCTAssertFalse(menuShows("Copy Paths"), "The batch menu should be gone with the batch.")
        app.typeKey(.escape, modifierFlags: [])

        // Removed picks that come back must not bring the batch back with them.
        undo()
        let restored = [sidebarWorktree("first"), sidebarWorktree("second")]
        waitUntil("undo brings a removed worktree back") { restored.contains(where: \.exists) }
        let row = try XCTUnwrap(restored.first(where: \.exists))
        row.rightClick()
        XCTAssertNotNil(shownMenuItem("Remove Worktree…"), "A restored row should have its own menu.")
        XCTAssertFalse(menuShows("Copy Paths"), "A restored row should not be part of a batch.")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSwitchingToABranchThatOnlyExistsOnTheRemoteTracksIt() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let remote = try sandbox.makeRemote(for: repository)
        let elsewhere = try sandbox.clone(remote, named: "elsewhere")
        try elsewhere.git("switch", "--quiet", "-c", "from-elsewhere")
        let pushed = try elsewhere.commit("other.txt", "from elsewhere\n", message: "start from-elsewhere")
        try elsewhere.git("push", "--quiet", "--set-upstream", "origin", "from-elsewhere")
        try repository.git("fetch", "--quiet")
        try launch(with: repository.workspace())

        chooseMenu("Project", "Switch Branch…")
        assertExists(branchField, "The Switch Branch sheet did not come up.")
        app.typeText("from-elsewhere")
        let row = sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "origin/from-elsewhere")).element(boundBy: 0)
        assertExists(row, "The remote branch should be offered.")
        // A name the remote has means that branch, not a new one off main.
        XCTAssertFalse(sheet.buttons["Create Branch “from-elsewhere”"].exists, "Typing a remote branch's name must not offer to create it.")
        let confirm = sheet.buttons["Switch"]
        waitUntil("the remote branch can be switched to") { confirm.isEnabled }
        confirm.click()

        assertGone(sheet, "The sheet should close after the switch.")
        waitUntil("the repository is on the remote branch") { try repository.currentBranch == "from-elsewhere" }
        XCTAssertEqual(try repository.upstream(of: "from-elsewhere"), "origin/from-elsewhere", "The new branch should track the remote one.")
        XCTAssertEqual(try repository.sha(of: "HEAD"), pushed, "The branch should start where the remote one is.")
        XCTAssertEqual(try repository.branches.sorted(), ["from-elsewhere", "main"], "No other branch should be made.")
        assertExists(sidebarWorktree("from-elsewhere"), "The sidebar should show the branch that is checked out now.")
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
