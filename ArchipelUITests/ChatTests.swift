import ArchipelCore
import XCTest

/// Agent sessions shown as a chat, driven over the Agent Client Protocol instead of a terminal.
/// A Perl script stands in for `opencode acp` (`installChatAgentStub()`); the client, the chat
/// and everything the window shows of it are the real thing. What the prompt says decides what
/// the stub does with the turn.
final class ChatTests: ArchipelUITestCase {
    private var settingsWindow: XCUIElement { app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").element(boundBy: 0) }

    private func openCodeChat() -> Session {
        Session(title: "OpenCode", agent: .opencode, interface: .acp)
    }

    /// Starts the app with one OpenCode chat and waits until the agent is up and the composer is
    /// there. OpenCode is the default agent so that File > New OpenCode Session is never disabled
    /// while the app is still looking for installed agents.
    @discardableResult
    private func launchWithChat(_ stub: ChatAgentStub, in repository: FixtureRepository) throws -> AgentLaunch {
        try launch(with: repository.workspace(sessions: [openCodeChat()]), defaultAgent: "opencode")
        let started = try waitForChatLaunch(1, of: stub)
        assertExists(chatComposer, "The chat should offer its composer once OpenCode is up.")
        return started
    }

    private func waitUntilTheTurnHasEnded(file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("the window shows the turn has ended", file: file, line: line) {
            !self.agentsStatus.contains("working") && !self.agentsStatus.contains("waiting")
        }
    }

    /// The preference Settings > Agents stores for "New sessions open in: Chat", as a launch
    /// argument. The app keeps the preferences as JSON data, and the argument domain reads `<hex>`
    /// as data.
    private func preferringChat(for agentID: String) throws -> [String] {
        let preferences = try JSONSerialization.data(withJSONObject: [agentID: ["interface": SessionInterface.acp.rawValue]])
        return ["-settings.agentPreferences", "<\(preferences.map { String(format: "%02x", $0) }.joined())>"]
    }

    // MARK: Conversation

    func testAChatAnswersAPromptAndTheTurnFinishes() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        let started = try launchWithChat(stub, in: repository)

        XCTAssertTrue(started.ran(in: repository.url), "The chat agent should run in its worktree, not in \(started.workingDirectory).")
        assertExists(tab("OpenCode"), "The chat should have a tab like any session.")
        assertExists(chatWelcome("OpenCode"), "An empty chat should welcome the user.")
        // The mode the agent offers in session/new is a control under the composer.
        assertExists(chatControl("mode"), "The agent's mode should show under the composer.")
        XCTAssertEqual(chatControl("mode").value as? String, "Build")
        waitUntil("the window shows the agent idle") { self.agentsStatus == "None working" }

        sendChatPrompt("hello there")
        assertExists(chatAgentMessage(containing: "Echo: hello there"), "The agent's reply should show below the prompt.")
        assertGone(chatWelcome("OpenCode"), "The welcome should give way to the conversation.")
        waitUntilTheTurnHasEnded()
        // A finished turn is what proves the conversation exists, so only now is its id kept.
        waitUntil("the conversation id is saved") {
            try sandbox.savedWorkspace().allSessions.first?.agentSessionID == "ses_stub1"
        }
        XCTAssertEqual(try stub.prompts(), ["hello there"])
    }

    func testAToolCallShowsAsCompleted() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launchWithChat(stub, in: repository)

        sendChatPrompt("read it with a tool")
        let row = chatToolCall("Read README.md")
        assertExists(row, "The tool call should get a row in the transcript.")
        waitUntil("the tool call reads as completed") { row.label == "Read README.md, completed" }
        assertExists(chatAgentMessage(containing: "I read README.md."), "The reply after the tool call should show.")
        waitUntilTheTurnHasEnded()
    }

    // MARK: Permissions

    func testAllowingAPermissionRequestCompletesTheTurn() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launchWithChat(stub, in: repository)

        sendChatPrompt("edit it with permission")
        assertExists(chatPermissionCard, "The request should show as a card in the chat.")
        // The chat reports the request as a hook would, so the window shows it the same way.
        waitUntil("the window shows the chat waiting for the user") { self.agentsStatus.contains("1 waiting for you") }
        assertExists(mainWindow.images["Needs your approval"], "The sidebar row should say what the chat is waiting for.")

        let allow = chatPermissionButton("allow")
        assertExists(allow, "The card should offer to allow the edit.")
        allow.click()
        assertGone(chatPermissionCard, "An answered request should leave the chat.")
        assertExists(chatAgentMessage(containing: "Allowed: edited notes.txt."), "The agent should carry on once allowed.")
        waitUntilTheTurnHasEnded()
        XCTAssertEqual(try stub.permissionAnswers(), ["once"], "Allow should answer with OpenCode's allow-once option.")
    }

    func testRejectingAPermissionRequestEndsTheTurn() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launchWithChat(stub, in: repository)

        sendChatPrompt("edit it with permission")
        assertExists(chatPermissionCard, "The request should show as a card in the chat.")
        let reject = chatPermissionButton("reject")
        assertExists(reject, "The card should offer to reject the edit.")
        reject.click()

        assertGone(chatPermissionCard, "An answered request should leave the chat.")
        let row = chatToolCall("Edit notes.txt")
        assertExists(row, "The rejected edit should stay in the transcript.")
        waitUntil("the rejected edit reads as failed") { row.label == "Edit notes.txt, failed" }
        assertExists(chatSendButton, "The turn should be over, so the composer offers Send again.")
        waitUntilTheTurnHasEnded()
        XCTAssertEqual(try stub.permissionAnswers(), ["reject"], "Reject should answer with OpenCode's reject option.")
    }

    // MARK: Stopping

    func testStopCancelsARunningTurn() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launchWithChat(stub, in: repository)

        // A slow turn that the agent finishes by itself: the window shows it working meanwhile.
        sendChatPrompt("take it slow")
        assertExists(chatAgentMessage(containing: "Working slowly."), "The first chunk should show while the turn runs.")
        waitUntil("the window shows the chat working") { self.agentsStatus.contains("1 agent working") }
        assertExists(chatStopButton, "A running turn should offer Stop in place of Send.")
        try stub.finishSlowTurn()
        assertExists(chatSendButton, "A finished turn should offer Send again.")
        waitUntilTheTurnHasEnded()

        sendChatPrompt("slow once more")
        let stop = chatStopButton
        assertExists(stop, "A running turn should offer Stop in place of Send.")
        stop.click()
        waitUntilChatAgentReceived("session/cancel", for: "ses_stub1", from: stub)
        assertExists(chatSendButton, "A stopped turn should offer Send again.")
        assertGone(chatStopButton, "Stop should go once the turn is over.")
        waitUntilTheTurnHasEnded()

        // Not only shown as sendable: the next prompt goes out and is answered.
        sendChatPrompt("are you there")
        assertExists(chatAgentMessage(containing: "Echo: are you there"), "The chat should take prompts again after a stop.")
    }

    // MARK: Keeping the conversation

    func testARelaunchRestoresTheConversation() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launchWithChat(stub, in: repository)

        sendChatPrompt("remember this")
        assertExists(chatAgentMessage(containing: "Echo: remember this"), "The agent's reply should show.")
        waitUntil("the conversation id is saved") {
            try sandbox.savedWorkspace().allSessions.first?.agentSessionID == "ses_stub1"
        }

        quit()
        try launch(keepingState: true, defaultAgent: "opencode")
        try waitForChatLaunch(2, of: stub)
        assertExists(chatUserMessage("remember this"), "The earlier prompt should be back after the relaunch.")
        assertExists(chatAgentMessage(containing: "Echo: remember this"), "The earlier reply should be back after the relaunch.")
        waitUntilChatAgentReceived("session/load", for: "ses_stub1", from: stub)
        XCTAssertEqual(try stub.received("session/new").count, 1, "Restoring must not start a second conversation as well.")
    }

    func testSwitchingToTheTerminalAndBackKeepsTheConversation() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launchWithChat(stub, in: repository)

        sendChatPrompt("before the switch")
        assertExists(chatAgentMessage(containing: "Echo: before the switch"), "The agent's reply should show.")
        waitUntil("the conversation id is saved") {
            try sandbox.savedWorkspace().allSessions.first?.agentSessionID == "ses_stub1"
        }
        waitUntilTheTurnHasEnded()

        chooseMenu("Tab", "Switch to Terminal")
        // The second launch of the stub overall: the chat's, then the terminal's.
        let terminal = try waitForLaunch(2, recordedIn: stub.launches)
        XCTAssertEqual(terminal.argument(after: "-s"), "ses_stub1", "The terminal should resume the chat's conversation: \(terminal.arguments)")
        XCTAssertFalse(terminal.arguments.contains("acp"), "The terminal runs the CLI itself, not its chat server: \(terminal.arguments)")
        assertGone(chatComposer, "The terminal should take the chat's place.")
        waitUntil("the session is saved as a terminal") {
            try sandbox.savedWorkspace().allSessions.map(\.interface) == [.terminal]
        }

        chooseMenu("Tab", "Switch to Chat")
        try waitForChatLaunch(2, of: stub)
        assertExists(chatUserMessage("before the switch"), "Switching back should show the earlier prompt again.")
        assertExists(chatAgentMessage(containing: "Echo: before the switch"), "Switching back should show the earlier reply again.")
        waitUntilChatAgentReceived("session/load", for: "ses_stub1", from: stub)
        XCTAssertEqual(try stub.received("session/new").count, 1, "Switching back must load the conversation, not start another.")
    }

    // MARK: Choosing the interface

    func testANewSessionOpensAsAChatWhenThatIsTheAgentsDefault() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launch(with: repository.workspace(), defaultAgent: "opencode", arguments: preferringChat(for: "opencode"))

        chooseMenu("File", "New OpenCode Session")
        try waitForChatLaunch(1, of: stub)
        assertExists(chatComposer, "With Chat as OpenCode's default, a plain new session should open as a chat.")
        waitUntil("the session is saved as a chat") {
            try sandbox.savedWorkspace().allSessions.map(\.interface) == [.acp]
        }
        XCTAssertEqual(try AgentLaunch.all(in: stub.launches).count, 1, "Nothing should have started OpenCode in a terminal.")
    }

    func testANewSessionOpensInTheTerminalByDefaultAndOpenInOffersTheChat() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launch(with: repository.workspace(), defaultAgent: "opencode")

        chooseMenu("File", "New OpenCode Session")
        let terminal = try waitForLaunch(1, recordedIn: stub.launches)
        XCTAssertFalse(terminal.arguments.contains("acp"), "By default a new session runs the CLI in a terminal: \(terminal.arguments)")
        XCTAssertTrue(terminal.argument(after: "-s")?.hasPrefix("ses_") == true, "OpenCode is given its conversation id up front: \(terminal.arguments)")
        XCTAssertFalse(chatComposer.exists, "A terminal session has no composer.")

        chooseSubmenu("File", "Open In", "New OpenCode Session in Chat")
        try waitForChatLaunch(1, of: stub)
        assertExists(chatComposer, "Open In should start the other interface, the chat.")
        waitUntil("both sessions are saved with their interfaces") {
            try sandbox.savedWorkspace().allSessions.map(\.interface) == [.terminal, .acp]
        }
    }

    // MARK: Ending

    func testAChatWhoseAgentQuitOffersRestart() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launchWithChat(stub, in: repository)

        sendChatPrompt("crash right now")
        let restart = chatRestartButton
        assertExists(restart, "A chat whose agent quit should offer Restart.")
        assertExists(chatText("OpenCode quit unexpectedly"), "The chat should say that the agent quit.")
        assertGone(chatComposer, "Nothing can be sent to an agent that is gone.")
        assertExists(chatUserMessage("crash right now"), "The transcript should stay after the agent quit.")

        restart.click()
        try waitForChatLaunch(2, of: stub)
        assertExists(chatComposer, "Restart should bring the composer back.")
        assertGone(chatRestartButton, "Restart should leave the ended state.")
        sendChatPrompt("hello again")
        assertExists(chatAgentMessage(containing: "Echo: hello again"), "The restarted chat should answer.")
        waitUntilTheTurnHasEnded()
    }

    // MARK: Settings

    func testChoosingChatInSettingsMakesItTheDefaultAndPersists() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installChatAgentStub()
        try launch(with: repository.workspace(), defaultAgent: "opencode")

        let picker = openOpenCodeInterfaceSettings()
        XCTAssertTrue(isChosen(picker.radioButtons["Terminal"]), "New sessions should open in the terminal until the user says otherwise.")
        picker.radioButtons["Chat"].click()
        waitUntil("Chat is chosen") { self.isChosen(picker.radioButtons["Chat"]) }
        app.typeKey("w", modifierFlags: .command)
        assertGone(settingsWindow, "⌘W should close Settings.")

        chooseMenu("File", "New OpenCode Session")
        try waitForChatLaunch(1, of: stub)
        assertExists(chatComposer, "After choosing Chat, a plain new session should open as a chat.")
        waitUntil("the session is saved, so the relaunch finds it") {
            try sandbox.savedWorkspace().allSessions.map(\.interface) == [.acp]
        }

        // Settings are written as they change, so a relaunch finds the choice where it was left.
        quit()
        try launch(keepingState: true, defaultAgent: "opencode")
        let relaunched = openOpenCodeInterfaceSettings()
        XCTAssertTrue(isChosen(relaunched.radioButtons["Chat"]), "The choice should survive a relaunch.")
    }

    // MARK: Helpers

    /// Opens Settings > Agents > OpenCode and returns its "New sessions open in" picker.
    private func openOpenCodeInterfaceSettings(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        assertExists(settingsWindow, "⌘, should open Settings.", file: file, line: line)
        settingsWindow.toolbars.buttons["Agents"].click()
        waitUntil("Settings shows Agents", file: file, line: line) { self.settingsWindow.title == "Agents" }
        selectAgent("opencode", named: "OpenCode", in: settingsWindow, file: file, line: line)
        let picker = settingsWindow.descendants(matching: .any).matching(identifier: "settings.agents.opencode.interface").element(boundBy: 0)
        assertExists(picker, "OpenCode can run as a chat, so its settings should offer the choice.", file: file, line: line)
        return picker
    }

    /// A segment of a segmented picker. Which of the two ways it reports the selection depends on
    /// the macOS version.
    private func isChosen(_ segment: XCUIElement) -> Bool {
        segment.isSelected || segment.value as? Int == 1
    }

    /// Picks an item from a submenu of the menu bar. Hovered and then confirmed with Return, as in
    /// `LaunchPresetTests`: the submenu's items have no frame until hovering their parent opens it.
    private func chooseSubmenu(_ menu: String, _ submenu: String, _ item: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.menuBars.menuBarItems[menu]
        assertExists(bar, "No \(menu) menu.", file: file, line: line)
        bar.click()
        let parent = bar.menuItems[submenu]
        assertExists(parent, "No \(submenu) in the \(menu) menu.", file: file, line: line)
        parent.hover()
        let entry = parent.menuItems[item]
        waitUntil("the \(submenu) submenu opens", file: file, line: line) { entry.frame.width > 0 }
        XCTAssertTrue(entry.isEnabled, "\(menu) > \(submenu) > \(item) is disabled.", file: file, line: line)
        entry.hover()
        waitUntil("\(item) is highlighted", file: file, line: line) { entry.isSelected }
        app.typeKey(.return, modifierFlags: [])
    }
}
