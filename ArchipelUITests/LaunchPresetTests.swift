import ArchipelCore
import XCTest

/// Launch presets end to end: a preset picked from a menu reaches the agent's command line, the
/// session keeps those arguments when the preset changes later, and ⌘T follows whichever preset
/// Settings marks as the default. A recording stub stands in for Claude Code, so every launch can
/// be read back.
final class LaunchPresetTests: ArchipelUITestCase {
    private var settingsWindow: XCUIElement { app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").element(boundBy: 0) }

    /// Opus is one of the presets a fresh install comes with, so these tests need no setup to use it.
    private let opus = (menuTitle: "Claude Code: Opus", tabTitle: "Claude Code (Opus)")

    func testStartingASessionFromAPresetInThePlusMenu() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installRecordingAgentStub(named: "claude")
        try launch(with: repository.workspace(sessions: [.shell("One"), .shell("Two")]))

        // Split first, so the test can tell "the pane whose plus was used" from "the focused pane".
        assertExists(tab("Two"), "Both seeded sessions should have tabs.")
        tab("Two").click()
        waitUntil("the tab to split off is selected") { self.tab("Two").isSelected }
        chooseMenu("Tab", "Split Right")
        waitUntil("there are two panes") { self.panes.count == 2 }

        // The new pane on the right has the focus, so the left one only gets the session if the
        // menu passes its own pane along.
        let leftPlus = try XCTUnwrap(panes.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX })
        startSession(from: opus.menuTitle, using: leftPlus)

        let started = try waitForLaunch(1, recordedIn: stub.launches)
        XCTAssertEqual(started.argument(after: "--model"), "opus", "The preset's arguments should reach the agent: \(started.arguments)")
        assertExists(tab(opus.tabTitle), "The tab should be titled after the agent and the preset.")
        waitUntil("the new session is selected") { self.tab(self.opus.tabTitle).isSelected }
        waitUntil("the session is saved in the pane whose plus was used") {
            let workspace = try sandbox.savedWorkspace()
            guard let session = workspace.allSessions.first(where: { $0.title == self.opus.tabTitle }) else { return false }
            let panes = workspace.allWorktrees[0].panes
            return panes.count == 2 && panes[0].tabs.map(\.content).contains(.session(session.id))
        }
        let saved = try XCTUnwrap(sandbox.savedWorkspace().allSessions.first { $0.title == opus.tabTitle })
        XCTAssertEqual(saved.arguments, "--model opus", "The session should carry a copy of the preset's arguments.")
        XCTAssertEqual(started.sessionID, saved.id.uuidString)
    }

    func testASessionKeepsItsPresetArgumentsAfterThePresetChanges() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installRecordingAgentStub(named: "claude")
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")

        let plus = panes.element(boundBy: 0)
        startSession(from: opus.menuTitle, using: plus)
        let first = try waitForLaunch(1, recordedIn: stub.launches)
        XCTAssertEqual(first.argument(after: "--model"), "opus", "The session should start with the preset's arguments: \(first.arguments)")

        openAgentSettings()
        let arguments = settingsWindow.textFields
            .matching(identifier: "settings.presets.claude.arguments")
            .matching(NSPredicate(format: "value == %@", "--model opus"))
            .element(boundBy: 0)
        assertExists(arguments, "Settings should list the Opus preset's arguments.")
        startEditing(arguments)
        // A model none of the seeded presets name, so its field can only be the one just edited.
        replaceText(with: "--model edited")
        app.typeKey(.return, modifierFlags: [])
        let editedArguments = settingsWindow.textFields
            .matching(identifier: "settings.presets.claude.arguments")
            .matching(NSPredicate(format: "value == %@", "--model edited"))
            .element(boundBy: 0)
        assertExists(editedArguments, "The preset should hold the new arguments.")
        app.typeKey("w", modifierFlags: .command)
        assertGone(settingsWindow, "⌘W should close Settings.")

        // Proof the edit took: without it, the restart below would pass for the wrong reason.
        app.typeKey("k", modifierFlags: .command)
        assertExists(paletteField, "⌘K should open the palette.")
        app.typeText("New Claude Code Session: Opus")
        let command = paletteRow(startingWith: "New Claude Code Session: Opus")
        assertExists(command, "The palette should offer the preset.")
        waitUntil("the preset's command is selected") { command.isSelected }
        app.typeKey(.return, modifierFlags: [])
        let edited = try waitForLaunch(2, recordedIn: stub.launches)
        XCTAssertEqual(edited.argument(after: "--model"), "edited", "A new session should get the edited arguments: \(edited.arguments)")
        assertExists(tab("\(opus.tabTitle) 2"), "The second session from the preset should be numbered.")

        tab(opus.tabTitle).click()
        waitUntil("the first session is selected") { self.tab(self.opus.tabTitle).isSelected }
        chooseMenu("Tab", "Restart Session")
        let restarted = try waitForLaunch(3, recordedIn: stub.launches)
        XCTAssertEqual(restarted.sessionID, first.sessionID, "Restart Session should restart the focused session.")
        XCTAssertEqual(restarted.argument(after: "--model"), "opus",
                       "A session keeps the arguments it started with, whatever happens to its preset: \(restarted.arguments)")
    }

    func testNewSessionFollowsTheDefaultPreset() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let stub = try sandbox.installRecordingAgentStub(named: "claude")
        try launch(with: repository.workspace(), defaultAgent: "claude")

        openAgentSettings()
        let add = settingsWindow.buttons.matching(identifier: "settings.presets.claude.add").element(boundBy: 0)
        assertExists(add, "Claude Code's presets should have an Add button.")
        // The Agents pane can be taller than the screen.
        for _ in 0..<10 where !add.isHittable {
            settingsWindow.scrollViews.element(boundBy: 0).scroll(byDeltaX: 0, deltaY: -200)
        }
        let presetArguments = settingsWindow.textFields.matching(identifier: "settings.presets.claude.arguments")
        let seeded = presetArguments.count
        add.click()
        waitUntil("a preset is added") { presetArguments.count == seeded + 1 }

        // Adding selects the new row, which is what Set as Default acts on.
        let toggleDefault = settingsWindow.buttons.matching(identifier: "settings.presets.claude.toggleDefault").element(boundBy: 0)
        waitUntil("Set as Default is offered for the new preset") { toggleDefault.isEnabled && toggleDefault.label == "Set as Default" }
        toggleDefault.click()
        // SwiftUI's Table reports itself as an outline.
        let badge = settingsWindow.outlines.staticTexts.matching(NSPredicate(format: "value == %@", "Default")).element(boundBy: 0)
        assertExists(badge, "The default preset should be marked in the table.")

        let added = presetArguments.element(boundBy: seeded)
        startEditing(added)
        replaceText(with: "--permission-mode plan")
        app.typeKey(.return, modifierFlags: [])
        waitUntil("the new preset holds its arguments") { added.value as? String == "--permission-mode plan" }
        app.typeKey("w", modifierFlags: .command)
        assertGone(settingsWindow, "⌘W should close Settings.")

        app.typeKey("t", modifierFlags: .command)
        let withDefault = try waitForLaunch(1, recordedIn: stub.launches)
        XCTAssertEqual(withDefault.argument(after: "--permission-mode"), "plan", "⌘T should use the default preset: \(withDefault.arguments)")
        assertExists(tab("Claude Code"), "⌘T is not a preset pick, so the tab keeps the plain agent name.")
        waitUntil("the session follows the default instead of copying it") {
            try sandbox.savedWorkspace().allSessions.map(\.arguments) == [nil]
        }

        openAgentSettings()
        // Reopened Settings may have lost the selection. The badge is plain text, so clicking it
        // selects its row instead of starting an edit.
        assertExists(badge, "The default should still be marked after reopening Settings.")
        badge.click()
        waitUntil("Clear Default is offered") { toggleDefault.isEnabled && toggleDefault.label == "Clear Default" }
        toggleDefault.click()
        assertGone(badge, "Clearing the default should unmark the preset.")
        app.typeKey("w", modifierFlags: .command)
        assertGone(settingsWindow, "⌘W should close Settings.")

        app.typeKey("t", modifierFlags: .command)
        let withoutDefault = try waitForLaunch(2, recordedIn: stub.launches)
        XCTAssertNotEqual(withoutDefault.sessionID, withDefault.sessionID, "⌘T should start a second session.")
        XCTAssertNil(withoutDefault.argument(after: "--permission-mode"), "Without a default, ⌘T adds no preset arguments: \(withoutDefault.arguments)")
        XCTAssertNil(withoutDefault.argument(after: "--model"), "No seeded preset is a default, so none may leak in: \(withoutDefault.arguments)")
    }

    // MARK: Helpers

    /// Picks a preset from a pane's plus menu, under its New Session with Preset submenu.
    ///
    /// Hovered and then confirmed with Return: a click on an item of this pop-up menu is
    /// synthesized but never reaches its action, and the submenu's items have no frame until
    /// hovering their parent opens it. Queried through the plus button, because the File menu
    /// holds items of the same titles.
    private func startSession(from preset: String, using plus: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        assertExists(plus, "The pane should have a plus button.", file: file, line: line)
        plus.click()
        let submenu = plus.menuItems["New Session with Preset"]
        assertExists(submenu, "The plus menu should offer New Session with Preset.", file: file, line: line)
        submenu.hover()
        let item = submenu.menuItems[preset]
        waitUntil("the submenu opens", file: file, line: line) { item.frame.width > 0 }
        XCTAssertTrue(item.isEnabled, "\(preset) is disabled.", file: file, line: line)
        item.hover()
        waitUntil("\(preset) is highlighted", file: file, line: line) { item.isSelected }
        app.typeKey(.return, modifierFlags: [])
    }

    /// Puts the cursor in a preset's field. A click on a row that isn't selected only selects
    /// it and gives the focus to the row's first field, so the second click is what starts
    /// editing this one.
    private func startEditing(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        field.click()
        if !hasKeyboardFocus(field) { field.click() }
        waitUntil("the field is being edited", file: file, line: line) { self.hasKeyboardFocus(field) }
    }

    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        element.value(forKey: "hasKeyboardFocus") as? Bool ?? false
    }

    private func openAgentSettings() {
        app.typeKey(",", modifierFlags: .command)
        assertExists(settingsWindow, "⌘, should open Settings.")
        settingsWindow.toolbars.buttons["Agents"].click()
        waitUntil("Settings shows Agents") { self.settingsWindow.title == "Agents" }
    }
}
