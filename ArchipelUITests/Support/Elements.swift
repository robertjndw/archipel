import XCTest

/// The parts of the window the tests look for, in one place so a change to the app's accessibility
/// tree is fixed here and not in every test.
///
/// Queries end in `element(boundBy: 0)` and never in `firstMatch`. `firstMatch` is answered by a
/// shortcut inside the app that does not see every label SwiftUI reports (a project's name in the
/// sidebar, for one), so it misses elements that the full snapshot finds.
extension ArchipelUITestCase {
    private func named(_ name: String) -> NSPredicate {
        // SwiftUI reports a Text as its value in some containers and as its label in others.
        NSPredicate(format: "label == %@ OR value == %@ OR title == %@", name, name, name)
    }

    // MARK: Sidebar

    func sidebarProject(_ name: String) -> XCUIElement {
        mainWindow.staticTexts.matching(identifier: "sidebar.project").matching(named(name)).element(boundBy: 0)
    }

    func sidebarWorktree(_ name: String) -> XCUIElement {
        mainWindow.staticTexts.matching(identifier: "sidebar.worktree").matching(named(name)).element(boundBy: 0)
    }

    var sidebarWorktrees: XCUIElementQuery {
        mainWindow.staticTexts.matching(identifier: "sidebar.worktree")
    }

    /// The title of the session peek, which names the session or, without one, the worktree. The
    /// popover is a window of its own, so it is looked for in the whole app.
    var peekTitle: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar.peek.title").element(boundBy: 0)
    }

    func peekTitle(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar.peek.title").matching(named(name)).element(boundBy: 0)
    }

    // MARK: Panes and tabs

    /// Not only buttons: a tab is one element combined from its parts, and while its session is
    /// starting or working it reports itself as the progress indicator it contains.
    var tabs: XCUIElementQuery {
        mainWindow.descendants(matching: .any).matching(identifier: "pane.tab")
    }

    func tab(_ title: String) -> XCUIElement {
        tabs.matching(named(title)).element(boundBy: 0)
    }

    /// Every pane ends in its own New Session button, which makes those a count of the panes.
    var panes: XCUIElementQuery {
        mainWindow.descendants(matching: .any).matching(identifier: "pane.newSession")
    }

    // MARK: Inspector

    func showChanges() {
        chooseMenu("View", "Show Changes")
        assertExists(commitMessageField, "The Changes tab did not show its commit area.")
    }

    func unstagedChange(_ fileName: String) -> XCUIElement {
        change(fileName, identifier: "changes.unstaged")
    }

    func stagedChange(_ fileName: String) -> XCUIElement {
        change(fileName, identifier: "changes.staged")
    }

    private func change(_ fileName: String, identifier: String) -> XCUIElement {
        // The row reads as "notes.txt, Modified": name, folder and kind combined.
        let startsWithName = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", fileName, fileName)
        return mainWindow.descendants(matching: .any).matching(identifier: identifier).matching(startsWithName).element(boundBy: 0)
    }

    var commitMessageField: XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: "changes.commitMessage").element(boundBy: 0)
    }

    var commitButton: XCUIElement {
        mainWindow.buttons.matching(identifier: "changes.primaryAction").element(boundBy: 0)
    }

    // MARK: Command palette

    var paletteField: XCUIElement {
        mainWindow.textFields.matching(identifier: "palette.query").element(boundBy: 0)
    }

    var paletteRows: XCUIElementQuery {
        mainWindow.buttons.matching(identifier: "palette.row")
    }

    func paletteRow(startingWith title: String) -> XCUIElement {
        paletteRows.matching(NSPredicate(format: "label BEGINSWITH %@", title)).element(boundBy: 0)
    }

    // MARK: Sheets

    var sheet: XCUIElement { mainWindow.sheets.element(boundBy: 0) }

    /// The search field of the Add Worktree and Switch Branch sheets.
    var branchField: XCUIElement { sheet.textFields["Branch"] }

    /// Replaces what a focused text field holds.
    func replaceText(with text: String) {
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
    }
}
