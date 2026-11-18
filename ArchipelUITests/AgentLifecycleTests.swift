import ArchipelCore
import XCTest

/// What happens to an agent session between its first launch and its last: how Codex is wired to
/// the hook helper, how a conversation survives a restart or a relaunch, and the commands that
/// lead the user to a session or clear it. A recording stub stands in for the agent, so every
/// launch can be compared with the one before it.
final class AgentLifecycleTests: ArchipelUITestCase {
    /// A line's comment button in the diff gutter. Side by side, both gutters list their rows, so
    /// the same label can come up more than once.
    private func gutterButton(_ label: String) -> XCUIElement {
        mainWindow.buttons.matching(NSPredicate(format: "label == %@", label)).element(boundBy: 0)
    }

    func testCodexRunsInItsWorktreeAndReportsThroughTheHook() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        let stub = try sandbox.installRecordingAgentStub(named: "codex")
        try launch(with: repository.workspace(linkedWorktrees: [feature]))

        // A linked worktree, so the folder it runs in cannot be the project's by accident.
        sidebarWorktree("feature").click()
        assertExists(mainWindow(titled: "fixture - feature"), "Clicking the worktree should select it.")
        mainWindow.buttons["Codex"].click()
        assertExists(tab("Codex"), "Starting Codex should open its tab.")
        let started = try waitForLaunch(1, recordedIn: stub.launches)

        XCTAssertTrue(started.ran(in: feature.path), "Codex should run in the worktree it was started in, not in \(started.workingDirectory).")
        XCTAssertEqual(started.socket, hookSocket)
        waitUntil("the session is saved under the id the agent was given") {
            try sandbox.savedWorkspace().allSessions.map(\.id.uuidString) == [started.sessionID]
        }
        XCTAssertNotEqual(started.arguments.first, "resume", "A new session has no conversation to resume.")
        // Turn ends come through notify, and the terminal notifications are kept to approvals so
        // the app can read every one of them as a request for permission.
        let overrides = started.configOverrides
        XCTAssertTrue(overrides.contains(#"tui.notifications=["approval-requested"]"#), "Codex should only notify about approvals: \(overrides)")
        XCTAssertTrue(overrides.contains(#"tui.notification_method="osc9""#), "Codex should notify through the terminal: \(overrides)")
        XCTAssertTrue(overrides.contains(#"tui.notification_condition="always""#), "Codex should notify while focused too: \(overrides)")
        let notify = try XCTUnwrap(started.codexNotifyCommand, "Codex should be given a notify command: \(overrides)")
        XCTAssertEqual(notify.dropFirst(), ["codex-notify"], "The helper tells Codex's payload from Claude's by this argument.")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: notify[0]), "Codex was pointed at a hook helper that is not there: \(notify[0])")
        // Codex has no hook for its start, so the app counts it as up once the terminal is.
        waitUntil("the window shows Codex idle") { self.agentsStatus == "None working" }

        // Running the command exactly as configured proves the override reaches the app.
        try sendCodexNotification(
            ["type": "agent-turn-complete", "thread-id": "codex-thread", "last-assistant-message": "Done."],
            command: notify,
            launch: started
        )
        waitUntil("the thread id from the notification is saved") {
            try sandbox.savedWorkspace().allSessions.first?.agentSessionID == "codex-thread"
        }

        chooseMenu("Tab", "Restart Session")
        let resumed = try waitForLaunch(2, recordedIn: stub.launches)
        XCTAssertEqual(resumed.arguments.first, "resume", "A restart should resume the Codex thread: \(resumed.arguments)")
        XCTAssertEqual(resumed.arguments.last, "codex-thread", "Codex takes the thread to resume as its last argument.")
        XCTAssertEqual(resumed.codexNotifyCommand, notify, "A resumed Codex must still report to the app.")
        XCTAssertTrue(resumed.ran(in: feature.path))
    }

    func testAClaudeConversationIsResumedAfterARelaunch() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installRecordingAgentStub(named: "claude")
        let session = Session.claude()
        try launch(with: repository.workspace(sessions: [session]))

        let first = try waitForLaunch(1, recordedIn: stub.launches)
        XCTAssertEqual(first.sessionID, session.id.uuidString)
        // The app picks the conversation id up front, so it knows what to resume without asking.
        let conversation = try XCTUnwrap(first.argument(after: "--session-id"), "A new Claude session should be given its conversation id: \(first.arguments)")
        XCTAssertNil(first.argument(after: "--resume"), "A session without a saved conversation has nothing to resume.")

        // Only a first turn puts the conversation on disk, so only then is the id worth keeping.
        try sendHook(["hook_event_name": "UserPromptSubmit", "session_id": conversation], hook: hookHelper.path, launch: first)
        try sendHook(["hook_event_name": "Stop", "session_id": conversation], hook: hookHelper.path, launch: first)
        waitUntil("the conversation id is saved") {
            try sandbox.savedWorkspace().allSessions.first?.agentSessionID == conversation
        }

        quit()
        try launch(keepingState: true)
        assertExists(tab("Claude Code"), "The session should be back after the relaunch.")
        let relaunched = try waitForLaunch(2, recordedIn: stub.launches)
        XCTAssertEqual(relaunched.sessionID, session.id.uuidString, "The relaunched agent should report to the same session.")
        XCTAssertEqual(relaunched.argument(after: "--resume"), conversation, "The agent should resume the saved conversation: \(relaunched.arguments)")
        XCTAssertNil(relaunched.argument(after: "--session-id"), "Resuming must not start a second conversation as well.")
        XCTAssertNotNil(relaunched.argument(after: "--settings"), "A resumed agent still needs its hooks.")
        XCTAssertTrue(relaunched.ran(in: repository.url))
    }

    func testRestartKeepsTheConversationAndANewConversationStartsOver() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installRecordingAgentStub(named: "claude")
        try launch(with: repository.workspace(sessions: [.claude()]))

        let first = try waitForLaunch(1, recordedIn: stub.launches)
        let conversation = try XCTUnwrap(first.argument(after: "--session-id"))
        let hook = hookHelper.path
        try sendHook(["hook_event_name": "SessionStart", "session_id": conversation], hook: hook, launch: first)
        try sendHook(["hook_event_name": "UserPromptSubmit", "session_id": conversation], hook: hook, launch: first)
        try sendHook(["hook_event_name": "Stop", "session_id": conversation], hook: hook, launch: first)
        waitUntil("the conversation id is saved") {
            try sandbox.savedWorkspace().allSessions.first?.agentSessionID == conversation
        }
        // A finished turn has nothing in flight, so the restart should not ask first.
        waitUntil("the window shows the turn has ended") { !self.agentsStatus.contains("working") }

        chooseMenu("Tab", "Restart Session")
        let resumed = try waitForLaunch(2, recordedIn: stub.launches)
        XCTAssertEqual(resumed.sessionID, first.sessionID, "A restart is the same session, so its hooks must keep finding it.")
        XCTAssertEqual(resumed.argument(after: "--resume"), conversation, "Restart Session should resume the conversation: \(resumed.arguments)")
        XCTAssertNil(resumed.argument(after: "--session-id"), "Resuming must not start a second conversation as well.")

        // A turn in flight is what a restart would throw away, so this time the app asks first.
        try sendHook(["hook_event_name": "UserPromptSubmit", "session_id": conversation], hook: hook, launch: resumed)
        waitUntil("the window shows the agent working") { self.agentsStatus.contains("1 agent working") }
        chooseMenu("Tab", "Restart with a New Conversation")
        let confirm = sheet.buttons["Restart"]
        assertExists(confirm, "Restarting a working agent should ask first.")
        confirm.click()

        let fresh = try waitForLaunch(3, recordedIn: stub.launches)
        XCTAssertEqual(fresh.sessionID, first.sessionID)
        XCTAssertNil(fresh.argument(after: "--resume"), "A new conversation must not resume the old one: \(fresh.arguments)")
        let newConversation = try XCTUnwrap(fresh.argument(after: "--session-id"), "The new conversation should get an id of its own: \(fresh.arguments)")
        XCTAssertNotEqual(newConversation, conversation)
        // The new id is only kept once a turn proves it exists, like the first one was.
        waitUntil("the old conversation id is forgotten") {
            try sandbox.savedWorkspace().allSessions.map(\.agentSessionID) == [nil]
        }
    }

    func testNextSessionNeedingAttentionOpensItInAnotherWorktree() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installRecordingAgentStub(named: "claude")
        let waiting = Session.claude()
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        let featureWithAgent = Worktree(path: feature.path, branch: "feature", sessions: [waiting])
        try launch(with: repository.workspace(sessions: [.shell()], linkedWorktrees: [featureWithAgent]))
        assertExists(mainWindow(titled: "fixture - main"), "The main checkout should be selected at launch.")
        assertExists(tab("Shell"), "The shell in the main checkout should be what the window shows.")

        // Sent as the agent's hook would, to a session in a worktree the user is not looking at.
        try sendHook(["hook_event_name": "PermissionRequest", "session_id": "waiting-conversation", "tool_name": "Bash"],
                     hook: hookHelper.path, sessionID: waiting.id.uuidString, socket: hookSocket)
        waitUntil("the window shows a session waiting for the user") { self.agentsStatus.contains("1 waiting for you") }
        XCTAssertTrue(mainWindow(titled: "fixture - main").exists, "A request must not move the selection by itself.")

        chooseMenu("Tab", "Next Session Needing Attention")
        assertExists(mainWindow(titled: "fixture - feature"), "The command should switch to the worktree of the waiting session.")
        assertExists(tab("Claude Code"), "The waiting session's tab should be shown.")
        waitUntil("the waiting session's tab is selected") { self.tab("Claude Code").isSelected }
        // Shown for the first time, so it starts now, in its own worktree.
        let started = try waitForLaunch(1, recordedIn: stub.launches)
        XCTAssertEqual(started.sessionID, waiting.id.uuidString)
        XCTAssertTrue(started.ran(in: feature.path), "The agent should run in its own worktree, not in \(started.workingDirectory).")
    }

    func testMarkAsReadClearsAFinishedTurn() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installRecordingAgentStub(named: "claude")
        try launch(with: repository.workspace(sessions: [.claude()]))

        let started = try waitForLaunch(1, recordedIn: stub.launches)
        let conversation = try XCTUnwrap(started.argument(after: "--session-id"))
        let hook = hookHelper.path
        try sendHook(["hook_event_name": "SessionStart", "session_id": conversation], hook: hook, launch: started)
        try sendHook(["hook_event_name": "UserPromptSubmit", "session_id": conversation], hook: hook, launch: started)
        try sendHook(["hook_event_name": "Stop", "session_id": conversation, "last_assistant_message": "Done."], hook: hook, launch: started)
        // Being on screen is not enough to have seen a result, so the session on screen is unread.
        waitUntil("the finished turn is unread") { self.agentsStatus == "1 unread" }

        chooseMenu("Project", "Mark as Read")
        waitUntil("the window shows nothing left to read") { self.agentsStatus == "None working" }
        app.menuBars.menuBarItems["Project"].click()
        XCTAssertFalse(menuItem("Project", "Mark as Read").isEnabled, "With nothing unread there is nothing to mark.")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testBackgroundTasksShowABadgeAndGuardTheSession() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installRecordingAgentStub(named: "claude")
        try launch(with: repository.workspace(sessions: [.claude()]))

        let started = try waitForLaunch(1, recordedIn: stub.launches)
        let conversation = try XCTUnwrap(started.argument(after: "--session-id"))
        let hook = hookHelper.path
        let shell: [String: Any] = ["id": "b1", "type": "shell", "status": "running", "description": "Dev server", "command": "npm run dev"]
        func endTurn(leaving tasks: [[String: Any]]) throws {
            try sendHook(["hook_event_name": "UserPromptSubmit", "session_id": conversation], hook: hook, launch: started)
            try sendHook(
                ["hook_event_name": "Stop", "session_id": conversation, "last_assistant_message": "Done.", "background_tasks": tasks],
                hook: hook, launch: started
            )
        }
        // The tab is one element, so it reads its badge out as its value.
        let session = tab("Claude Code")

        try sendHook(["hook_event_name": "SessionStart", "session_id": conversation], hook: hook, launch: started)
        try endTurn(leaving: [shell])
        waitUntil("the tab says a background task is running") { session.value as? String == "1 background task running" }
        // The shell may be a server that never exits, so the turn is announced all the same.
        XCTAssertEqual(agentsStatus, "1 unread")

        chooseMenu("File", "Close Tab")
        let question = sheet.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "running a background task", "running a background task"))
            .element(boundBy: 0)
        assertExists(question, "Closing would stop the shell too, so the app should ask first.")
        sheet.buttons["Cancel"].click()
        assertExists(session, "Cancel should leave the session open.")

        try endTurn(leaving: [])
        waitUntil("the tab no longer says so") { session.value as? String != "1 background task running" }
    }

    func testMarkAsReadKeepsARequestNobodyAnswered() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installAskingAgentStub(named: "codex")
        try launch(with: repository.workspace(sessions: [Session(title: "Codex", agent: .codex)]))
        waitUntil("the window shows Codex idle") { self.agentsStatus == "None working" }

        // Codex asks for approval through a terminal notification and never says when it got one.
        try stub.ask()
        waitUntil("the request is waiting and unread") { self.agentsStatus == "1 waiting for you, 1 unread" }

        // Marking as read answers nothing, so the request has to stay where the user can find it.
        chooseMenu("Project", "Mark as Read")
        waitUntil("only the unread mark is gone") { self.agentsStatus == "1 waiting for you" }

        // Clicking into the session is the only sign there will ever be that it was dealt with.
        mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        waitUntil("the request counts as answered") { self.agentsStatus == "None working" }
    }

    func testReviewCommentsArePastedIntoTheAgent() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try repository.write("notes.txt", "first line\nsecond line\n")
        let stub = try sandbox.installRecordingAgentStub(named: "claude")
        try launch(with: repository.workspace(sessions: [.claude()]))

        // Comments are only pasted once the agent says it is at its prompt.
        let started = try waitForLaunch(1, recordedIn: stub.launches)
        let conversation = try XCTUnwrap(started.argument(after: "--session-id"))
        try sendHook(["hook_event_name": "SessionStart", "session_id": conversation], hook: hookHelper.path, launch: started)
        waitUntil("the window shows the agent idle at its prompt") { self.agentsStatus == "None working" }

        showChanges()
        assertExists(unstagedChange("notes.txt"), "The modified file should be listed.")
        unstagedChange("notes.txt").doubleClick()
        assertExists(tab("notes.txt (Working Tree)"), "Opening a change should give its diff a tab.")

        // The gutter is drawn, not made of views; it offers each visible line as a button of its own.
        let addComment = gutterButton("Add Comment to line 2")
        assertExists(addComment, "The added line should take a comment.")
        // The button is where VoiceOver puts its cursor, so it has to be where the row is drawn.
        let gutter = mainWindow.groups["Modified Line Comments"]
        XCTAssertEqual(addComment.frame.minY, gutter.frame.minY + addComment.frame.height, accuracy: 1,
                       "Line 2's button should sit on the second row of the gutter.")
        addComment.click()
        let commentField = app.popovers.textViews["Comment"]
        assertExists(commentField, "Clicking the line should open the comment editor.")
        commentField.click()
        app.typeText("Say which line this is")
        app.popovers.buttons["Add Comment"].click()
        assertGone(commentField, "Adding the comment should close the editor.")
        assertExists(gutterButton("Comment on line 2: Say which line this is"), "The line should show its comment.")

        let comments = mainWindow.buttons["1 review comment"]
        assertExists(comments, "The diff header should count the comment.")
        comments.click()
        let send = app.popovers.buttons["Send to Claude Code"]
        assertExists(send, "The worktree's only agent should be offered as the place to send the comments.")
        send.click()

        waitUntil("the session is shown to read what was pasted") { self.tab("Claude Code").isSelected }
        waitUntil("the comment is pasted into the agent") {
            let pasted = (try? String(contentsOf: stub.input, encoding: .utf8)) ?? ""
            return pasted.contains("Please address this review comment on your changes:")
                && pasted.contains("notes.txt:2")
                && pasted.contains("`second line`")
                && pasted.contains("Say which line this is")
        }

        // Sent comments are done with; the line takes a new one again.
        tab("notes.txt (Working Tree)").click()
        assertExists(gutterButton("Add Comment to line 2"), "A sent comment should be cleared from its line.")
        XCTAssertFalse(mainWindow.buttons["1 review comment"].exists, "Nothing should be left to send.")
    }
}
