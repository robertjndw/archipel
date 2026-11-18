import ArchipelCore
import XCTest

final class ProjectScriptTests: ArchipelUITestCase {
    /// The workspace of `repository.workspace()` with scripts on its project, which is quicker and
    /// steadier than typing them into the settings sheet in every test.
    private func workspace(for repository: FixtureRepository, setup: String = "", run: String = "") -> Workspace {
        var workspace = repository.workspace()
        let project = workspace.islands[0].projects[0]
        workspace.updateProject(id: project.id) { $0.scripts = ProjectScripts(setup: setup, run: run) }
        return workspace
    }

    private func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: name).path)
    }

    func testTheSetupScriptRunsInANewWorktree() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: workspace(for: repository, setup: "touch setup-ran"))

        chooseMenu("Project", "Add Worktree…")
        assertExists(branchField, "The Add Worktree sheet did not come up.")
        app.typeText("feature-setup")
        let create = sheet.buttons["Create"]
        waitUntil("the name has been checked") { create.isEnabled }
        create.click()

        assertGone(sheet, "The sheet should close once the worktree exists.")
        assertExists(tab("Setup"), "The setup script should run as a tab of its own.")
        let folder = sandbox.worktreesRoot.appending(path: "fixture/feature-setup")
        waitUntil("the script has run in the new worktree") { self.exists("setup-ran", in: folder) }
        XCTAssertFalse(exists("setup-ran", in: repository.url), "The main checkout is not a new worktree.")
    }

    func testRunStartsTheRunScriptInTheSelectedWorktree() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: workspace(for: repository, run: "touch run-ran"))

        XCTAssertEqual(tabs.count, 0)
        app.typeKey("r", modifierFlags: .command)

        assertExists(tab("Run"), "Run should open a tab for the script.")
        waitUntil("the script has run in the worktree") { self.exists("run-ran", in: repository.url) }
        waitUntil("the script's session is saved") {
            try sandbox.savedWorkspace().allSessions.map(\.title) == ["Run"]
        }

        // Running again restarts that tab and does not open another one.
        try FileManager.default.removeItem(at: repository.url.appending(path: "run-ran"))
        app.typeKey("r", modifierFlags: .command)
        waitUntil("the script has run again") { self.exists("run-ran", in: repository.url) }
        XCTAssertEqual(tabs.count, 1, "A second run should reuse the Run tab.")
    }

    func testRunSetupScriptRunsItInTheSelectedWorktree() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: workspace(for: repository, setup: "touch setup-ran"))

        chooseMenu("Project", "Run Setup Script")
        assertExists(tab("Setup"), "The setup script should run as a tab of its own.")
        waitUntil("the script has run in the worktree") { self.exists("setup-ran", in: repository.url) }
    }

    func testRunSetupScriptIsDisabledWithoutOne() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        app.menuBars.menuBarItems["Project"].click()
        XCTAssertFalse(menuItem("Project", "Run Setup Script").isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testRunWithoutAScriptOpensTheScriptSettings() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        app.typeKey("r", modifierFlags: .command)
        assertExists(sheet.staticTexts["Run Script"], "With nothing to run, Run should open the Scripts page.")
        XCTAssertEqual(tabs.count, 0, "Nothing was started.")
        sheet.buttons["Cancel"].click()
        assertGone(sheet, "Cancel should close the sheet.")
    }

    func testScriptsSetInTheProjectSettingsAreSavedAndUsed() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace())

        chooseMenu("Project", "Project Settings…")
        let scripts = sheet.radioButtons["Scripts"]
        assertExists(scripts, "The project settings did not come up.")
        scripts.click()
        let setup = sheet.textViews.element(boundBy: 0)
        let run = sheet.textViews.element(boundBy: 1)
        assertExists(run, "The Scripts page should have a field for each script.")
        setup.click()
        app.typeText("touch setup-ran")
        run.click()
        app.typeText("touch run-ran")
        sheet.buttons["Save"].click()

        assertGone(sheet, "Save should close the sheet.")
        waitUntil("the scripts are saved") {
            try sandbox.savedWorkspace().islands[0].projects[0].scripts == ProjectScripts(setup: "touch setup-ran", run: "touch run-ran")
        }

        // The saved scripts are the ones that run, for the next worktree and for Run.
        chooseMenu("Project", "Add Worktree…")
        assertExists(branchField, "The Add Worktree sheet did not come up.")
        app.typeText("feature-saved")
        let create = sheet.buttons["Create"]
        waitUntil("the name has been checked") { create.isEnabled }
        create.click()
        assertGone(sheet, "The sheet should close once the worktree exists.")
        let folder = sandbox.worktreesRoot.appending(path: "fixture/feature-saved")
        waitUntil("the setup script has run in the new worktree") { self.exists("setup-ran", in: folder) }

        chooseMenu("Project", "Run")
        waitUntil("the run script has run in the new worktree") { self.exists("run-ran", in: folder) }
    }
}
