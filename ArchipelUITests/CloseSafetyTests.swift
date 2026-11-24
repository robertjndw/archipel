import ArchipelCore
import XCTest

/// What closing tabs and quitting ask about first. A shell at its prompt has nothing to lose; a
/// shell running a command, a file with unsaved edits or an agent in the middle of a turn has.
/// No hook reports what runs in a shell, so the app asks the terminal, and the tests start a real
/// command there (see `LongRunningJob`).
final class CloseSafetyTests: ArchipelUITestCase {
    private var settingsWindow: XCUIElement { app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").element(boundBy: 0) }

    /// Starts the job in the only terminal on screen and waits until it runs.
    private func startLongRunningJob(_ job: LongRunningJob) {
        // One pane, so after a tab switch the only terminal is the selected tab's.
        let terminal = terminalsLeftToRight(1)[0]
        runInTerminal(LongRunningJob.command, in: terminal) { job.pid != nil }
    }

    // MARK: Closing one tab

    func testClosingAnIdleShellDoesNotAsk() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")

        // A command that has run and ended leaves the shell at its prompt, which is the state to test.
        let marker = repository.url.appending(path: "ran")
        let terminal = terminalSurfaces.element(boundBy: 0)
        assertExists(terminal, "The shell's terminal should be on screen.")
        runInTerminal("touch ran", in: terminal) { FileManager.default.fileExists(atPath: marker.path) }

        chooseMenu("File", "Close Tab")
        // A question would hold the tab back, so the tab going is the proof that none was asked.
        assertGone(tab("Shell"), "A shell at its prompt should close without asking.")
        XCTAssertFalse(sheet.exists, "Nothing runs in the shell, so there is nothing to ask about.")
        waitUntil("the session is gone from the workspace") { try sandbox.savedWorkspace().allSessions.isEmpty }
    }

    func testClosingAShellRunningACommandAsksFirst() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let job = try repository.writeLongRunningJob()
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")
        startLongRunningJob(job)
        let pid = try XCTUnwrap(job.pid)

        app.typeKey("w", modifierFlags: .command)
        assertExists(interruptionQuestion(containing: "sleep is running"), "Closing a shell with a running command should ask first and name the command.")
        sheet.buttons["Cancel"].click()
        assertGone(sheet, "Cancel should dismiss the question.")
        XCTAssertEqual(tabs.count, 1, "Cancel should leave the tab open.")
        XCTAssertTrue(job.isRunning, "Cancel should leave the command running.")

        chooseMenu("File", "Close Tab")
        let confirm = sheet.buttons["Close Tab"]
        assertExists(confirm, "The question should come back.")
        confirm.click()
        waitUntil("the tab is gone") { self.tabs.count == 0 }
        waitUntil("closing stopped the command") { kill(pid, 0) != 0 }
    }

    // MARK: Closing several tabs

    func testClosingTabsToTheRight() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell("One"), .shell("Two"), .shell("Three"), .shell("Four")]))
        assertExists(tab("Four"), "The seeded sessions should have tabs.")

        tab("Two").rightClick()
        chooseContextMenu("Close Tabs to the Right")

        assertGone(tab("Three"), "The tabs right of the clicked one should close.")
        assertGone(tab("Four"), "The tabs right of the clicked one should close.")
        XCTAssertTrue(tab("One").exists, "A tab left of the clicked one should stay.")
        XCTAssertTrue(tab("Two").exists, "The clicked tab should stay.")
        waitUntil("only the kept sessions are saved") { try sandbox.savedWorkspace().allSessions.map(\.title) == ["One", "Two"] }
    }

    func testClosingOtherTabsWaitsForTheAnswerAboutABusyShell() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let job = try repository.writeLongRunningJob()
        try launch(with: repository.workspace(sessions: [.shell("One"), .shell("Busy"), .shell("Three")]))
        assertExists(tab("Busy"), "The seeded sessions should have tabs.")
        tab("Busy").click()
        waitUntil("the busy tab is selected") { self.tab("Busy").isSelected }
        startLongRunningJob(job)

        // Busy comes before Three, so its question holds Three back.
        tab("One").rightClick()
        chooseContextMenu("Close Other Tabs")
        assertExists(interruptionQuestion(containing: "sleep is running"), "The busy shell should ask before it is closed.")
        sheet.buttons["Cancel"].click()
        assertGone(sheet, "Cancel should dismiss the question.")
        XCTAssertEqual(tabs.count, 3, "Cancel should keep the busy tab and the ones queued behind it.")
        XCTAssertTrue(job.isRunning, "Cancel should leave the command running.")

        tab("One").rightClick()
        chooseContextMenu("Close Other Tabs")
        let confirm = sheet.buttons["Close Tab"]
        assertExists(confirm, "The busy shell should ask again.")
        confirm.click()

        assertGone(tab("Busy"), "Confirming should close the busy tab.")
        assertGone(tab("Three"), "The tab queued behind the question should close once it is answered.")
        XCTAssertTrue(tab("One").exists, "The clicked tab should stay.")
        waitUntil("only the clicked session is saved") { try sandbox.savedWorkspace().allSessions.map(\.title) == ["One"] }
    }

    func testClosingOtherTabsGoesOnAfterDontSave() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell("One")]))
        assertExists(tab("One"), "The seeded session should have a tab.")

        app.typeKey("p", modifierFlags: .command)
        assertExists(paletteField, "Open Quickly did not come up.")
        app.typeText("notes.txt")
        let row = paletteRow(startingWith: "notes.txt")
        assertExists(row, "Open Quickly should list notes.txt.")
        row.click()
        assertExists(fileEditorTextView, "The file should open in the editor.")
        fileEditorTextView.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("scribble")
        waitUntil("the tab says it has unsaved changes") { self.tab("notes.txt").value as? String == "Unsaved changes" }
        // Opened after the file, so it sits behind it in the row and waits for its question.
        chooseMenu("File", "New Shell Session")
        waitUntil("the new session has a tab") { self.tabs.count == 3 }

        tab("One").rightClick()
        chooseContextMenu("Close Other Tabs")
        let question = sheet.staticTexts["Do you want to save the changes you made to notes.txt?"]
        assertExists(question, "The file with unsaved edits should ask before it is closed.")
        sheet.buttons["Don't Save"].click()

        waitUntil("the file and the session behind it are closed") { self.tabs.count == 1 }
        XCTAssertTrue(tab("One").exists, "The clicked tab should stay.")
        XCTAssertEqual(try String(contentsOf: repository.url.appending(path: "notes.txt"), encoding: .utf8), "first line\n",
                       "Don't Save must not write the edits.")
        waitUntil("only the clicked session is saved") { try sandbox.savedWorkspace().allSessions.map(\.title) == ["One"] }
    }

    // MARK: Quitting

    /// The tests launch with the question turned off, since `terminate()` between tests would
    /// otherwise stop at it. This one turns it on in Settings and ends by quitting for real, so the
    /// teardown finds the app gone.
    func testQuittingWhileAShellRunsACommandAsksFirst() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let job = try repository.writeLongRunningJob()
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")

        app.typeKey(",", modifierFlags: .command)
        assertExists(settingsWindow, "⌘, should open Settings.")
        settingsWindow.toolbars.buttons["General"].click()
        waitUntil("Settings shows General") { self.settingsWindow.title == "General" }
        let asks = settingsWindow.switches.matching(identifier: "settings.confirmsQuitWhileWorking").element(boundBy: 0)
        assertExists(asks, "General should offer to ask before quitting.")
        XCTAssertEqual(asks.value as? Int, 0, "The tests launch with the question turned off.")
        asks.click()
        waitUntil("the switch is on") { asks.value as? Int == 1 }
        app.typeKey("w", modifierFlags: .command)
        assertGone(settingsWindow, "⌘W should close Settings.")

        startLongRunningJob(job)

        let message = "Quit Archipel while a session is busy?"
        let question = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", message, message)).element(boundBy: 0)
        app.typeKey("q", modifierFlags: .command)
        assertExists(question, "Quitting with a command running in a shell should ask first.")
        app.buttons.matching(NSPredicate(format: "label == %@", "Cancel")).element(boundBy: 0).click()
        assertGone(question, "Cancel should dismiss the question.")
        XCTAssertEqual(app.state, .runningForeground, "Cancel should keep the app running.")
        XCTAssertTrue(job.isRunning, "Cancel should leave the command running.")

        app.typeKey("q", modifierFlags: .command)
        assertExists(question, "The question should come back.")
        app.buttons.matching(NSPredicate(format: "label == %@", "Quit")).element(boundBy: 0).click()
        waitUntil("the app has quit") { self.app.state == .notRunning }
    }
}
