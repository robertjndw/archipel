import ArchipelCore
import XCTest

/// Two panes side by side: which one has the keyboard, moving tabs between them, and the widths
/// they keep. Which pane's shell ran a command is told by where its file lands: each shell is sent
/// into a folder of its own first (see `moveShell`).
final class PaneTests: ArchipelUITestCase {
    private let left = "leftside"
    private let right = "rightside"

    /// Launches with the main checkout split into a Left and a Right shell, sends each shell into
    /// its own folder and leaves the keyboard in the left pane.
    private func launchSplitIntoFolders(
        _ repository: FixtureRepository,
        linkedWorktrees: [Worktree] = []
    ) throws -> Workspace {
        let workspace = repository.splitWorkspace(panes: [[.shell("Left")], [.shell("Right")]], linkedWorktrees: linkedWorktrees)
        try launch(with: workspace)
        assertExists(tab("Right"), "Both seeded sessions should have tabs.")
        let terminals = terminalsLeftToRight(2)
        // Each click focuses the clicked pane, so the left one goes last.
        moveShell(in: terminals[1], to: right, of: repository)
        moveShell(in: terminals[0], to: left, of: repository)
        waitForFocus(onPane: 0, of: workspace)
        return workspace
    }

    /// The focused pane is saved a moment after it changes, and by then the keyboard has been
    /// handed to its terminal too.
    private func waitForFocus(onPane index: Int, of workspace: Workspace, file: StaticString = #filePath, line: UInt = #line) {
        let pane = workspace.allWorktrees[0].panes[index].id
        waitUntil("pane \(index + 1) is focused", file: file, line: line) {
            try self.sandbox.savedWorkspace().allWorktrees[0].focusedPaneID == pane
        }
    }

    /// Types `touch name` wherever the keyboard is and returns the folder of the shell that ran it.
    private func shellThatRuns(_ name: String, in repository: FixtureRepository, file: StaticString = #filePath, line: UInt = #line) -> String? {
        app.typeText("touch \(name)\n")
        var ran: String?
        waitUntil("a shell has run touch \(name)", file: file, line: line) {
            ran = self.folder(holding: name, among: [self.left, self.right], in: repository)
            return ran != nil
        }
        return ran
    }

    // MARK: Focus

    func testFocusNextAndPreviousPaneMoveTheKeyboard() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let workspace = try launchSplitIntoFolders(repository)

        chooseMenu("Tab", "Focus Next Pane")
        waitForFocus(onPane: 1, of: workspace)
        XCTAssertEqual(shellThatRuns("nextprobe", in: repository), right, "After Focus Next Pane typing should reach the right pane's shell.")

        // The key Ghostty uses for the same. The menu claims it before the terminal does.
        app.typeKey("[", modifierFlags: .command)
        waitForFocus(onPane: 0, of: workspace)
        XCTAssertEqual(shellThatRuns("previousprobe", in: repository), left, "After ⌘[ typing should reach the left pane's shell.")

        // Two panes, so either direction wraps around to the other one.
        app.typeKey("]", modifierFlags: .command)
        waitForFocus(onPane: 1, of: workspace)
        chooseMenu("Tab", "Focus Previous Pane")
        waitForFocus(onPane: 0, of: workspace)
        XCTAssertEqual(shellThatRuns("backprobe", in: repository), left)
    }

    func testFocusPaneCommandsNeedASecondPane() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        try launch(with: repository.workspace(sessions: [.shell()]))
        assertExists(tab("Shell"), "The seeded session should have a tab.")

        app.menuBars.menuBarItems["Tab"].click()
        XCTAssertFalse(menuItem("Tab", "Focus Next Pane").isEnabled, "A single pane has nowhere to move the focus to.")
        XCTAssertFalse(menuItem("Tab", "Focus Previous Pane").isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Every pane's terminal mounts when a worktree comes back on screen. Only the focused pane's
    /// may take the keyboard, or the last one to mount would get it.
    func testTypingGoesToTheFocusedPaneAfterSwitchingWorktrees() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        let linked = Worktree(path: feature.path, branch: "feature", sessions: [.shell("Feature Shell")])
        let workspace = try launchSplitIntoFolders(repository, linkedWorktrees: [linked])

        sidebarWorktree("feature").click()
        assertExists(mainWindow(titled: "fixture - feature"), "Clicking the worktree should select it.")
        assertExists(tab("Feature Shell"), "The other worktree's session should be shown.")
        sidebarWorktree("main").click()
        assertExists(mainWindow(titled: "fixture - main"), "Clicking the main checkout should go back.")
        _ = terminalsLeftToRight(2)
        waitForFocus(onPane: 0, of: workspace)

        XCTAssertEqual(shellThatRuns("switchprobe", in: repository), left, "Typing should reach the focused left pane, not the last terminal to mount.")
    }

    // MARK: Moving tabs

    func testMovingATabToTheOtherPane() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let one = Session.shell("One"), two = Session.shell("Two"), three = Session.shell("Three")
        try launch(with: repository.splitWorkspace(panes: [[one, two], [three]]))
        assertExists(tab("Three"), "The seeded sessions should have tabs.")

        tab("One").rightClick()
        chooseContextMenu("Move to Other Pane")

        waitUntil("the tab is saved in the other pane") {
            let panes = try self.sandbox.savedWorkspace().allWorktrees[0].panes.map { $0.tabs.map(\.content) }
            return panes.count == 2 && panes[0] == [.session(two.id)]
                && Set(panes[1]) == [.session(three.id), .session(one.id)]
        }
        XCTAssertEqual(panes.count, 2, "Both panes still have a tab, so both stay.")
    }

    // MARK: Widths

    /// The divider is not dragged: XCUITest's drags of a split view divider are not reliable. The
    /// widths are seeded instead, as a drag would have left them, which is what has to survive.
    func testPaneWidthsAreKeptAcrossAWorktreeSwitchAndARelaunch() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let feature = try repository.addWorktree(branch: "feature", in: sandbox.worktreesRoot)
        let linked = Worktree(path: feature.path, branch: "feature", sessions: [.shell("Feature Shell")])
        // Uneven, but with the narrow pane still above the minimum width in a default size window.
        let share = 0.62
        try launch(with: repository.splitWorkspace(
            panes: [[.shell("Left")], [.shell("Right")]],
            widthShares: [share, 1 - share],
            linkedWorktrees: [linked]
        ))
        assertExists(tab("Right"), "Both seeded sessions should have tabs.")

        func assertShare(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
            _ = terminalsLeftToRight(2, file: file, line: line)
            // The dividers are placed a pass of the main queue after the panes appear.
            waitUntil("the left pane takes its share of the width \(when)", file: file, line: line) {
                guard let measured = self.leftPaneShare else { return false }
                return abs(measured - share) < 0.04
            }
        }

        assertShare("at launch")

        sidebarWorktree("feature").click()
        assertExists(mainWindow(titled: "fixture - feature"), "Clicking the worktree should select it.")
        sidebarWorktree("main").click()
        assertExists(mainWindow(titled: "fixture - main"), "Clicking the main checkout should go back.")
        assertShare("after a worktree switch")
        waitUntil("the widths are still saved") {
            let shares = try self.sandbox.savedWorkspace().allWorktrees[0].paneWidthShares
            return shares.count == 2 && abs(shares[0] - share) < 0.01
        }

        quit()
        try launch(keepingState: true)
        assertExists(tab("Right"), "The split should come back after a relaunch.")
        assertShare("after a relaunch")
    }
}
