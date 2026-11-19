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

    func testBouncingTheDockIsOffUntilTurnedOnAndStaysOn() throws {
        try launch()
        let bounce = openNotificationSettings()
        XCTAssertEqual(bounce.value as? Int, 0, "Bouncing the Dock is opt-in.")
        bounce.click()
        waitUntil("the switch is on") { bounce.value as? Int == 1 }
        app.typeKey("w", modifierFlags: .command)
        assertGone(settingsWindow, "⌘W should close Settings.")

        // Settings are written as they change, so a relaunch finds the switch where it was left.
        try launch(keepingState: true)
        let relaunched = openNotificationSettings()
        XCTAssertEqual(relaunched.value as? Int, 1, "The choice should survive a relaunch.")
    }

    private func openNotificationSettings() -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        assertExists(settingsWindow, "⌘, should open Settings.")
        settingsWindow.toolbars.buttons["Notifications"].click()
        let bounce = settingsWindow.switches.matching(identifier: "settings.bouncesDock").element(boundBy: 0)
        assertExists(bounce, "Notifications should offer to bounce the Dock icon.")
        return bounce
    }

    func testChoosingStatusBarItems() throws {
        try launch()
        let usage = mainWindow.descendants(matching: .any)["statusBar.usage"]
        assertExists(usage, "The status bar should show the usage limits by default.")

        app.typeKey(",", modifierFlags: .command)
        assertExists(settingsWindow, "⌘, should open Settings.")
        settingsWindow.toolbars.buttons["Appearance"].click()
        let preview = settingsWindow.descendants(matching: .any)["settings.statusBarPreview"]
        assertExists(preview, "Appearance should show the status bar preview.")
        // Appearance is taller than some screens, and then the status bar section starts out of view.
        for _ in 0..<10 where !preview.isHittable {
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        preview.rightClick()
        chooseFirstMenuItem()
        assertGone(usage, "Unchecking Usage limits on the preview should take it out of the status bar.")
        app.typeKey("w", modifierFlags: .command)
        assertGone(settingsWindow, "⌘W should close Settings.")

        // The status bar's own menu brings it back.
        mainWindow.buttons["Resources"].rightClick()
        chooseFirstMenuItem()
        assertExists(usage, "Checking Usage limits in the status bar's menu should show it again.")
    }

    /// Usage limits, the first item of the status bar's menu. Picked with the keyboard: XCUITest's
    /// clicks on the items of a menu AppKit pops up did not reach their action, and the menu can open
    /// where XCUITest does not count its items as hittable.
    private func chooseFirstMenuItem() {
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
    }
}
