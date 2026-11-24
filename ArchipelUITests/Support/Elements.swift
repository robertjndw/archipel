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

    /// Where the divider between two panes sits, as a fraction of their combined width (0.5 is the
    /// middle). Nil if there is no divider, e.g. before macOS 27.2, which has no split view there.
    ///
    /// The panes' split group reports the whole window as its frame, so the width is measured
    /// between the sidebar and inspector dividers instead, or the window edges if those are hidden.
    var paneDividerPosition: CGFloat? {
        let buttons = panes.allElementsBoundByIndex.map(\.frame)
        guard buttons.count == 2 else { return nil }
        let dividers = mainWindow.splitGroups.allElementsBoundByIndex
            .flatMap { $0.splitters.allElementsBoundByIndex.map(\.frame.midX) }
        let window = mainWindow.frame
        let firstTab = tabs.allElementsBoundByIndex.map(\.frame.minX).min() ?? buttons[0].minX
        let leading = dividers.filter { $0 < firstTab }.max() ?? window.minX
        let trailing = dividers.filter { $0 > buttons[1].maxX }.min() ?? window.maxX
        guard let divider = dividers.first(where: { $0 > buttons[0].maxX && $0 < buttons[1].minX }),
              trailing > leading else { return nil }
        return (divider - leading) / (trailing - leading)
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

    // MARK: Chat

    /// The text view prompts are typed into. The ended bar takes its place once the agent is gone.
    var chatComposer: XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: "chat.composer").element(boundBy: 0)
    }

    /// Send and Stop are one button that changes its identifier with the turn.
    var chatSendButton: XCUIElement {
        mainWindow.buttons.matching(identifier: "chat.send").element(boundBy: 0)
    }

    var chatStopButton: XCUIElement {
        mainWindow.buttons.matching(identifier: "chat.stop").element(boundBy: 0)
    }

    var chatRestartButton: XCUIElement {
        mainWindow.buttons.matching(identifier: "chat.restart").element(boundBy: 0)
    }

    /// What an empty chat shows above the composer.
    func chatWelcome(_ agentName: String) -> XCUIElement {
        chatText("Chat with \(agentName)")
    }

    /// A line of the chat that is not a message. Plain text reports what it says as its value and
    /// labelled elements as their label, so this takes either.
    func chatText(_ text: String) -> XCUIElement {
        mainWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).element(boundBy: 0)
    }

    /// The user's bubble reads as "You: " and the text.
    func chatUserMessage(_ text: String) -> XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: "chat.message.user")
            .matching(NSPredicate(format: "label == %@", "You: \(text)")).element(boundBy: 0)
    }

    /// A reply is Markdown, which may come out as more than one text, so this matches a part.
    func chatAgentMessage(containing text: String) -> XCUIElement {
        mainWindow.staticTexts.matching(identifier: "chat.message.agent")
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).element(boundBy: 0)
    }

    /// A tool call row reads as its title and its status, as in "Read README.md, completed".
    func chatToolCall(_ title: String) -> XCUIElement {
        mainWindow.buttons.matching(identifier: "chat.toolCall")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).element(boundBy: 0)
    }

    var chatPermissionCard: XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: "chat.permission").element(boundBy: 0)
    }

    /// `role` is the end of the button's identifier: `allow`, `allowAlways` or `reject`. Each
    /// answer has its identifier whatever the agent calls it.
    func chatPermissionButton(_ role: String) -> XCUIElement {
        mainWindow.buttons.matching(identifier: "chat.permission.\(role)").element(boundBy: 0)
    }

    /// One of the agent's settings under the composer, by the id the agent gave it.
    func chatControl(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: "chat.control.\(id)").element(boundBy: 0)
    }

    /// Types a prompt into the composer and sends it with Return, then waits for its bubble.
    /// Only letters and spaces: those sit on the same keys in every keyboard layout.
    func sendChatPrompt(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        assertExists(chatComposer, "The chat should have its composer.", file: file, line: line)
        chatComposer.click()
        app.typeText(text)
        app.typeKey(.return, modifierFlags: [])
        assertExists(chatUserMessage(text), "The prompt should show as the user's message.", file: file, line: line)
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
