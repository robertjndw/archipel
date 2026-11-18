import ArchipelCore
import XCTest

final class SettingsTests: ArchipelUITestCase {
    private var settingsWindow: XCUIElement { app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").element(boundBy: 0) }

    func testSettingsOpenAndSwitchPanes() throws {
        try launch()

        app.typeKey(",", modifierFlags: .command)
        assertExists(settingsWindow, "⌘, should open Settings.")
        for pane in ["Appearance", "Notifications", "Agents", "Worktrees", "About", "General"] {
            settingsWindow.toolbars.buttons[pane].click()
            waitUntil("Settings shows \(pane)") { self.settingsWindow.title == pane }
        }
    }

    func testClosingSettingsDoesNotCloseATab() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")

        app.typeKey(",", modifierFlags: .command)
        assertExists(settingsWindow, "⌘, should open Settings.")
        // ⌘W belongs to the window in front. With Settings there it must not end the session
        // in the window behind.
        app.typeKey("w", modifierFlags: .command)

        assertGone(settingsWindow, "⌘W should close Settings.")
        XCTAssertTrue(tab("Shell").exists, "The session tab behind Settings must survive ⌘W.")
        XCTAssertEqual(try sandbox.savedWorkspace().allSessions.count, 1)
    }
}
