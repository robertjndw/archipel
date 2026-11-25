import ArchipelCore
import XCTest

final class SyncTests: ArchipelUITestCase {
    /// Pull, Push and Fetch stay disabled until the app's first status poll of the worktree has
    /// come back, and only that poll tells Push from Publish Branch. The menu is read when it
    /// opens, so it is opened until the item shows up enabled.
    private func waitForProjectMenuItem(_ item: String, file: StaticString = #filePath, line: UInt = #line) {
        let entry = menuItem("Project", item)
        waitUntil("Project > \(item) is enabled", file: file, line: line) {
            self.app.menuBars.menuBarItems["Project"].click()
            let ready = entry.exists && entry.isEnabled
            self.app.typeKey(.escape, modifierFlags: [])
            return ready
        }
    }

    func testPublishingABranchThatHasNoUpstream() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let remote = try sandbox.makeRemote(for: repository)
        // A new branch the way git makes one: nothing on the remote and no upstream configured.
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        sidebarWorktree("feature").click()
        assertExists(mainWindow(titled: "fixture - feature"), "The feature worktree should be selected.")
        waitForProjectMenuItem("Publish Branch")
        app.menuBars.menuBarItems["Project"].click()
        XCTAssertFalse(menuItem("Project", "Push").exists, "A branch without an upstream is published, not pushed.")
        app.typeKey(.escape, modifierFlags: [])

        chooseMenu("Project", "Publish Branch")
        let local = try repository.sha(of: "feature")
        waitUntil("the remote has the branch") { try remote.sha(of: "refs/heads/feature") == local }
        XCTAssertEqual(try repository.upstream(of: "feature"), "origin/feature", "Publishing should set the upstream.")
        // From now on the same command is a plain push.
        waitForProjectMenuItem("Push")
    }

    func testPushingALocalCommitFromTheChangesTab() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let remote = try sandbox.makeRemote(for: repository)
        let local = try repository.commit("notes.txt", "first line\nsecond line\n", message: "add a second line")
        try launch(with: repository.workspace())

        showChanges()
        // With nothing left to commit the button offers the next step. Contains, not equals: the
        // arrow in front of the title may be read out as part of the label.
        let push = commitButton
        waitUntil("the button offers to push the commit") { push.label.contains("Push 1 Commit") && push.isEnabled }
        push.click()

        waitUntil("the remote has the commit") { try remote.sha(of: "refs/heads/main") == local }
        XCTAssertEqual(try repository.sha(of: "origin/main"), local, "The remote-tracking branch should follow the push.")
        XCTAssertEqual(try repository.sha(of: "HEAD"), local, "A push must not move the local branch.")
    }

    func testPullFastForwardsToTheRemote() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let remote = try sandbox.makeRemote(for: repository)
        let elsewhere = try sandbox.clone(remote, named: "elsewhere")
        let upstream = try elsewhere.commit("notes.txt", "first line\nfrom elsewhere\n", message: "change from elsewhere")
        try elsewhere.git("push", "--quiet")
        try launch(with: repository.workspace())

        waitForProjectMenuItem("Pull")
        chooseMenu("Project", "Pull")

        // Pull fetches first, so the app learns about the commit from the pull itself.
        waitUntil("main is fast-forwarded to the remote") { try repository.sha(of: "HEAD") == upstream }
        XCTAssertEqual(try repository.contents(of: "notes.txt"), "first line\nfrom elsewhere\n")
        XCTAssertEqual(try repository.git("status", "--porcelain"), "", "A fast-forward leaves nothing behind in the working tree.")
        XCTAssertEqual(try repository.currentBranch, "main")
    }

    func testPullRefusesADivergedBranch() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let remote = try sandbox.makeRemote(for: repository)
        let elsewhere = try sandbox.clone(remote, named: "elsewhere")
        let upstream = try elsewhere.commit("other.txt", "from elsewhere\n", message: "change from elsewhere")
        try elsewhere.git("push", "--quiet")
        let local = try repository.commit("notes.txt", "first line\nlocal line\n", message: "local change")
        try launch(with: repository.workspace())

        waitForProjectMenuItem("Pull")
        chooseMenu("Project", "Pull")

        // Sorting out a diverged branch needs someone in a terminal, so the app explains instead of
        // merging or rebasing on its own.
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "have diverged", "have diverged")
        ).element(boundBy: 0)
        assertExists(explanation, "A diverged branch should be refused with an explanation.")
        XCTAssertEqual(try repository.sha(of: "HEAD"), local, "A refused pull must leave the branch where it was.")
        XCTAssertEqual(try repository.sha(of: "origin/main"), upstream, "The pull should still have fetched.")
        XCTAssertEqual(try repository.git("status", "--porcelain"), "", "Nothing may be half merged.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url.appending(path: "other.txt").path),
                       "The remote's file must not reach the working tree.")

        // OK is the alert's default button.
        app.typeKey(.return, modifierFlags: [])
        assertGone(explanation, "OK should close the alert.")
    }

    func testFetchBringsInABranchThatOnlyExistsOnTheRemote() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let remote = try sandbox.makeRemote(for: repository)
        let elsewhere = try sandbox.clone(remote, named: "elsewhere")
        try elsewhere.git("switch", "--quiet", "-c", "from-elsewhere")
        let pushed = try elsewhere.commit("other.txt", "from elsewhere\n", message: "start from-elsewhere")
        try elsewhere.git("push", "--quiet", "--set-upstream", "origin", "from-elsewhere")
        XCTAssertThrowsError(try repository.sha(of: "refs/remotes/origin/from-elsewhere"), "Nothing has fetched the branch yet.")
        try launch(with: repository.workspace())

        waitForProjectMenuItem("Fetch")
        chooseMenu("Project", "Fetch")
        waitUntil("the branch is fetched") { try repository.sha(of: "refs/remotes/origin/from-elsewhere") == pushed }

        chooseMenu("Project", "Add Worktree…")
        assertExists(branchField, "The Add Worktree sheet did not come up.")
        app.typeText("from-elsewhere")
        let row = sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "origin/from-elsewhere")).element(boundBy: 0)
        assertExists(row, "The fetched branch should be offered as a remote branch.")
        XCTAssertFalse(sheet.buttons["Create Branch “from-elsewhere”"].exists,
                       "A name that exists on the remote means that branch, not a new one.")
        let add = sheet.buttons["Add"]
        waitUntil("the remote branch can be added") { add.isEnabled }
        add.click()

        assertGone(sheet, "The sheet should close once the worktree exists.")
        assertExists(sidebarWorktree("from-elsewhere"), "The new worktree should be in the sidebar.")
        waitUntil("the new branch tracks the remote one") { try repository.upstream(of: "from-elsewhere") == "origin/from-elsewhere" }
        XCTAssertEqual(try repository.sha(of: "from-elsewhere"), pushed, "The local branch should start at the fetched commit.")
        XCTAssertEqual(try repository.worktreePaths.count, 2)
    }

    func testABranchWhoseUpstreamWasDeletedIsOnlyPublishedAgainFromTheSyncMenu() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let remote = try sandbox.makeRemote(for: repository)
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        try repository.git("push", "--quiet", "--set-upstream", "origin", "feature")
        // What merging a pull request and deleting its branch leaves behind. main stays on the
        // remote, which is how the app tells a deleted branch from one that was never pushed.
        try remote.git("branch", "-D", "feature")
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        sidebarWorktree("feature").click()
        assertExists(mainWindow(titled: "fixture - feature"), "The feature worktree should be selected.")
        waitForProjectMenuItem("Fetch")
        chooseMenu("Project", "Fetch")
        waitUntil("the fetch has pruned the deleted branch") { (try? repository.sha(of: "refs/remotes/origin/feature")) == nil }

        showChanges()
        let sync = mainWindow.buttons.matching(NSPredicate(format: "label == %@", "Sync")).element(boundBy: 0)
        assertExists(sync, "The Changes header should have the sync menu.")
        waitUntil("the panel says the upstream is gone") { self.summary(of: sync) == "origin/feature no longer exists" }
        // One click on the main button would otherwise put a merged branch back on the remote.
        XCTAssertFalse(commitButton.label.contains("Publish") && commitButton.isEnabled, "The main button must not offer to publish the branch again.")
        XCTAssertFalse(commitButton.isEnabled, "With nothing to commit the main button has nothing to do.")
        // Nor does the Project menu, which can act on several worktrees at once.
        waitUntil("Project > Push is disabled") {
            self.app.menuBars.menuBarItems["Project"].click()
            defer { self.app.typeKey(.escape, modifierFlags: []) }
            let push = self.menuItem("Project", "Push")
            return push.exists && !push.isEnabled
        }

        sync.click()
        let publish = shownMenuItem("Publish Branch")
        XCTAssertEqual(publish?.isEnabled, true, "The sync menu should still offer to publish the branch again.")
        // By keyboard: clicks on the items of a menu AppKit pops up do not reach their action.
        // Pull is disabled without an upstream, so the first item Down lands on is Publish Branch.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        let local = try repository.sha(of: "feature")
        waitUntil("the remote has the branch again") { try remote.sha(of: "refs/heads/feature") == local }
        XCTAssertEqual(try repository.upstream(of: "feature"), "origin/feature", "Publishing should set the upstream again.")
        waitUntil("the panel says the branch is up to date") { self.summary(of: sync) == "Up to date with origin/feature" }
    }

    /// What the sync menu's button reads out: its summary of the branch.
    private func summary(of button: XCUIElement) -> String? {
        button.value as? String
    }

    func testProjectSyncItemsAreDisabledWithoutARemote() throws {
        // No makeRemote: the fixture has a branch and commits but no remote and no upstream.
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())
        assertExists(mainWindow(titled: "fixture - main"), "The seeded worktree should be selected.")

        // The items are disabled until the first status poll, and the Push item is only titled
        // "Publish Branch" once that poll has come back for a branch without an upstream. Waiting for
        // the title tells a loaded status from a missing one, whatever the items' state is.
        var state: (pull: Bool, publish: Bool, fetch: Bool)?
        waitUntil("the status is loaded and the Project menu says Publish Branch") {
            self.app.menuBars.menuBarItems["Project"].click()
            defer { self.app.typeKey(.escape, modifierFlags: []) }
            let publish = self.menuItem("Project", "Publish Branch")
            guard publish.exists else { return false }
            state = (
                self.menuItem("Project", "Pull").isEnabled,
                publish.isEnabled,
                self.menuItem("Project", "Fetch").isEnabled
            )
            return true
        }

        // Each of them could only fail, and the Changes tab's sync menu offers none of them either.
        XCTAssertEqual(state?.pull, false, "Pull needs an upstream to pull from.")
        XCTAssertEqual(state?.publish, false, "There is no remote to publish the branch to.")
        XCTAssertEqual(state?.fetch, false, "There is no remote to fetch from.")
    }
}
