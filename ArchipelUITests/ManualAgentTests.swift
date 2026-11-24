import ArchipelCore
import XCTest

/// A Claude the user types into a shell tab by hand. The tab acts as a Claude session while it
/// runs and is a shell again afterwards. A Perl script stands in for Claude (see
/// `installManualClaudeStub`), but the terminal and the hook helper it reports through are real.
final class ManualAgentTests: ArchipelUITestCase {
    /// Detection waits on the resource monitor's scans, the slowest thing in the window. Generous,
    /// since `waitUntil` returns as soon as the condition holds.
    private static let scanTimeout: TimeInterval = 30

    private var settingsWindow: XCUIElement { app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").element(boundBy: 0) }

    /// The sidebar row draws its worktree's only session as the agent's logo, labelled with the
    /// agent's name. The tab is one combined element that hides its icon, so the sidebar is where
    /// this is reliably readable. A shell's logo is labelled "Shell".
    private var claudeIcon: XCUIElement { mainWindow.images["Claude Code"] }

    /// The summary reads "None working" when nothing is, so a plain "working" would always match.
    private var agentIsWorking: Bool {
        agentsStatus.contains("agent working") || agentsStatus.contains("agents working")
    }

    private var settingsFile: URL { sandbox.home.appending(path: ".claude/settings.json") }
    private var hookLink: URL { sandbox.support.appending(path: "bin/archipel-hook") }

    /// The tab's shell starts through login(1), which puts back the real HOME, so it reads the
    /// profile of whoever runs the tests and never gets the sandbox on its PATH. A bare `claude`
    /// would start the real one; the stub is typed by its full path instead.
    private func typeClaude(_ stub: ManualClaudeStub) {
        typeIntoTerminal(stub.executable.path)
    }

    /// Focuses the terminal and types the command. The click lands in the middle of the window,
    /// which is the terminal with a single session.
    private func typeIntoTerminal(_ command: String) {
        mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeText(command + "\n")
    }

    private func waitForStub(_ stub: ManualClaudeStub) -> (pid: Int32, sessionID: String)? {
        var started: (pid: Int32, sessionID: String)?
        waitUntil("the typed claude is running") {
            started = stub.started()
            return started != nil
        }
        return started
    }

    // MARK: Scans and progress

    func testClaudeTypedIntoAShellTabActsAsClaudeWhileItRuns() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installManualClaudeStub()
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")
        XCTAssertFalse(claudeIcon.exists, "A plain shell must not look like Claude.")

        typeClaude(stub)
        let started = try XCTUnwrap(waitForStub(stub))
        let saved = try sandbox.savedWorkspace().allSessions
        XCTAssertEqual(started.sessionID, saved.first?.id.uuidString, "The tab should hand its session id to what runs in it.")

        // Found by a scan or the check after a title change, so it is not instant.
        waitUntil("the sidebar shows Claude", timeout: Self.scanTimeout) { self.claudeIcon.exists }
        waitUntil("the window shows the new Claude idle") { !self.agentIsWorking }

        try stub.progressOn()
        waitUntil("the progress report makes the window show Claude working") { self.agentsStatus == "1 agent working" }

        // A clear only ends the turn after a quiet period, so this waits for longer than that.
        try stub.progressOff()
        waitUntil("the cleared progress ends the turn", timeout: Self.scanTimeout) { !self.agentIsWorking }
        XCTAssertTrue(claudeIcon.exists, "Claude should still show after its turn ends.")

        // The saved session stays a shell, so the next launch doesn't start Claude.
        XCTAssertEqual(try sandbox.savedWorkspace().allSessions.map(\.agent), [.shell])

        try stub.exit()
        waitUntil("the sidebar goes back to a shell", timeout: Self.scanTimeout) { !self.claudeIcon.exists }
        XCTAssertFalse(agentIsWorking)
        XCTAssertEqual(try sandbox.savedWorkspace().allSessions.map(\.agent), [.shell])
    }

    // MARK: Closing and restarting

    private func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func testClosingAShellTabWithAHandStartedClaudeAsksFirst() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installManualClaudeStub()
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")

        typeClaude(stub)
        let started = try XCTUnwrap(waitForStub(stub))
        waitUntil("the sidebar shows Claude", timeout: Self.scanTimeout) { self.claudeIcon.exists }

        // Only a session with a turn in flight asks, so an idle Claude would close without a word.
        try stub.progressOn()
        waitUntil("the progress report makes the window show Claude working") { self.agentsStatus == "1 agent working" }

        // The saved session is a shell, so without detection this would close without asking.
        chooseMenu("File", "Close Tab")
        let confirm = sheet.buttons["Close Tab"]
        assertExists(confirm, "Closing a hand-started Claude that is working should ask first.")
        let question = sheet.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Claude Code will be stopped", "Claude Code will be stopped"))
            .element(boundBy: 0)
        assertExists(question, "The dialog should say the detected Claude is what stops.")
        sheet.buttons["Cancel"].click()
        assertGone(sheet, "Cancel should dismiss the dialog.")
        XCTAssertEqual(tabs.count, 1, "Cancel should leave the tab open.")
        XCTAssertTrue(isRunning(started.pid), "Cancel should leave Claude running.")

        // A detected Claude never saves a conversation id, so there is nothing to start over.
        tab("Shell").rightClick()
        waitUntil("the tab menu is open") { self.app.menuItems["Restart Session"].exists }
        // The Session menu in the menu bar always carries the item, disabled without a
        // conversation, and app-wide queries see it too. The tab menu leaves it out instead.
        let freshRestarts = app.menuItems.matching(
            NSPredicate(format: "title == %@ AND enabled == true", "Restart with a New Conversation")
        )
        XCTAssertEqual(freshRestarts.count, 0, "A hand-started Claude has no saved conversation to replace.")
        app.typeKey(.escape, modifierFlags: [])

        chooseMenu("File", "Close Tab")
        assertExists(confirm, "The dialog should come back.")
        confirm.click()
        waitUntil("the tab is gone") { self.tabs.count == 0 }
        waitUntil("closing stopped Claude") { !self.isRunning(started.pid) }
    }

    // MARK: Hooks in the user's settings

    private var hookSwitch: XCUIElement { settingsWindow.switches["settings.claudeUserHooks"] }

    private func openAgentSettings() {
        app.typeKey(",", modifierFlags: .command)
        assertExists(settingsWindow, "⌘, should open Settings.")
        settingsWindow.toolbars.buttons["Agents"].click()
        waitUntil("Settings shows Agents") { self.settingsWindow.title == "Agents" }
        selectAgent("claude", named: "Claude Code", in: settingsWindow)
    }

    private func clickHookSwitch() {
        waitUntil("the switch for Claude in a shell tab is shown") { self.hookSwitch.exists }
        // It sits below Claude's presets, which can push it out of view.
        let form = settingsWindow.scrollViews.containing(.switch, identifier: "settings.claudeUserHooks").element(boundBy: 0)
        for _ in 0..<10 where !hookSwitch.isHittable {
            form.scroll(byDeltaX: 0, deltaY: -200)
        }
        hookSwitch.click()
    }

    /// The `hooks` object of the sandbox settings file, or nil while the file doesn't exist.
    private func hooksInSettingsFile() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile) else { return nil }
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return settings["hooks"] as? [String: Any]
    }

    private func command(for event: String, in hooks: [String: Any]) -> String? {
        let groups = hooks[event] as? [[String: Any]] ?? []
        let handlers = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        return handlers.compactMap { $0["command"] as? String }.first { $0.contains("user-settings") }
    }

    func testClaudeTypedIntoAShellTabReportsThroughTheUserSettingsHooks() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installManualClaudeStub()
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")

        openAgentSettings()
        clickHookSwitch()
        // The test points CLAUDE_CONFIG_DIR into the sandbox, so entries here mean the app honoured
        // it and left the real settings file alone.
        waitUntil("the entries are in the sandbox's settings file") { try self.hooksInSettingsFile() != nil }
        let hooks = try XCTUnwrap(try hooksInSettingsFile())
        for event in ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd"] {
            XCTAssertNotNil(command(for: event, in: hooks), "\(event) should carry Archipel's entry.")
        }
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: hookLink.path)
        XCTAssertEqual(destination, hookHelper.path, "The entries should point at the bundled helper through the link.")
        let command = try XCTUnwrap(command(for: "SessionStart", in: hooks))
        XCTAssertTrue(command.contains(hookLink.path), "The entry should run the link, not the bundle: \(command)")
        XCTAssertTrue(command.contains(hookSocket), "The entry should report to this app's socket: \(command)")

        app.typeKey("w", modifierFlags: .command)
        assertGone(settingsWindow, "⌘W should close Settings.")

        typeClaude(stub)
        let started = try XCTUnwrap(waitForStub(stub))
        waitUntil("the sidebar shows Claude", timeout: Self.scanTimeout) { self.claudeIcon.exists }

        // Claude picks its own conversation id, so the app only learns it from the hooks.
        let conversation = UUID().uuidString.lowercased()
        func send(_ event: String, _ extra: [String: Any] = [:]) throws {
            try stub.runHook(["hook_event_name": event, "session_id": conversation].merging(extra) { $1 }, command: command)
        }

        try send("SessionStart", ["source": "startup"])
        waitUntil("the window shows Claude idle") { !self.agentIsWorking }

        try send("UserPromptSubmit")
        waitUntil("the window shows Claude working") { self.agentsStatus.contains("1 agent working") }

        try send("PermissionRequest", ["tool_name": "Bash"])
        waitUntil("the window shows Claude waiting for the user") { self.agentsStatus.contains("1 waiting for you") }

        try send("Stop", ["last_assistant_message": "Done."])
        waitUntil("the window shows the turn has ended") {
            !self.agentIsWorking && !self.agentsStatus.contains("waiting")
        }
        XCTAssertTrue(claudeIcon.exists, "Claude should still show after its turn ends.")
        XCTAssertEqual(try sandbox.savedWorkspace().allSessions.map(\.agent), [.shell],
                       "The conversation of a hand-started Claude must not turn the saved session into a Claude one.")
        XCTAssertEqual(started.sessionID, try sandbox.savedWorkspace().allSessions.first?.id.uuidString)

        try send("SessionEnd", ["reason": "other"])
        try stub.exit()
        waitUntil("the sidebar goes back to a shell", timeout: Self.scanTimeout) { !self.claudeIcon.exists }

        openAgentSettings()
        clickHookSwitch()
        // The file may stay behind; only Archipel's entries have to go.
        waitUntil("Archipel's entries are gone from the settings file") {
            guard let hooks = try self.hooksInSettingsFile() else { return true }
            return hooks.keys.allSatisfy { self.command(for: $0, in: hooks) == nil }
        }
        // Codex's hooks point at the same link, so it has to outlive Claude's entries.
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: hookLink.path),
            "Turning the shell hooks off should leave the helper link for Codex."
        )
    }
}
