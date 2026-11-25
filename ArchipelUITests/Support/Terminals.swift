import ArchipelCore
import Foundation
import XCTest

/// Terminals, the file editor and split worktrees. A terminal is a text area to accessibility, the
/// same as the editor, so both are looked up by identifier and never as "the first text view".
extension ArchipelUITestCase {
    /// The terminals on screen in the main window. Only the selected tab of each pane shows one.
    var terminalSurfaces: XCUIElementQuery {
        mainWindow.descendants(matching: .any).matching(identifier: "terminal.surface")
    }

    /// The terminals on screen from the leftmost pane to the rightmost, once there are `count`.
    func terminalsLeftToRight(_ count: Int, file: StaticString = #filePath, line: UInt = #line) -> [XCUIElement] {
        waitUntil("\(count) terminals are on screen", file: file, line: line) { self.terminalSurfaces.count == count }
        return terminalSurfaces.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The text view of the file tab on screen.
    var fileEditorTextView: XCUIElement {
        mainWindow.textViews.matching(identifier: "editor.text").element(boundBy: 0)
    }

    /// The search field Cmd-F opens over a terminal.
    var terminalSearchBar: XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: "terminal.search").element(boundBy: 0)
    }

    var terminalSearchField: XCUIElement {
        mainWindow.textFields.matching(identifier: "terminal.search.field").element(boundBy: 0)
    }

    /// Clicks into the terminal and types the command until `done` says the shell has run it. The
    /// terminal draws itself, so there is no prompt to wait for, and keys typed before the shell is
    /// up can be lost. Stick to letters and spaces, which sit on the same keys in every layout.
    func runInTerminal(
        _ command: String,
        in terminal: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line,
        until done: @escaping () -> Bool
    ) {
        waitUntil("the shell has run \"\(command)\"", timeout: 30, file: file, line: line) {
            if done() { return true }
            terminal.click()
            app.typeText(command + "\n")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            return done()
        }
    }

    /// Has the shell in `terminal` make a folder in the worktree and change into it, so a file a
    /// later command touches shows which pane's shell ran it. Every shell of a worktree starts in
    /// the same folder, and the screen is not something the tests can read reliably.
    func moveShell(
        in terminal: XCUIElement,
        to folder: String,
        of repository: FixtureRepository,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let directory = repository.url.appending(path: folder, directoryHint: .isDirectory)
        runInTerminal("mkdir \(folder)", in: terminal, file: file, line: line) {
            FileManager.default.fileExists(atPath: directory.path)
        }
        // The shell is at its prompt now, so it takes these without a retry.
        app.typeText("cd \(folder)\n")
        app.typeText("touch here\n")
        waitUntil("the shell is in \(folder)", file: file, line: line) {
            FileManager.default.fileExists(atPath: directory.appending(path: "here").path)
        }
    }

    /// Which of the folders made by `moveShell` the shell that ran `touch name` sits in. Nil until
    /// one of them holds the file.
    func folder(holding name: String, among folders: [String], in repository: FixtureRepository) -> String? {
        folders.first { FileManager.default.fileExists(atPath: repository.url.appending(path: "\($0)/\(name)").path) }
    }

    /// The left pane's share of the width of two panes. Measured at the divider where there is a
    /// split view, otherwise from the terminals, which fill their panes but for a few points of gap.
    var leftPaneShare: CGFloat? {
        if let position = paneDividerPosition { return position }
        let frames = terminalSurfaces.allElementsBoundByIndex.map(\.frame).sorted { $0.minX < $1.minX }
        guard frames.count == 2, frames[0].width + frames[1].width > 0 else { return nil }
        return frames[0].width / (frames[0].width + frames[1].width)
    }

    /// The confirmation that closing or restarting a session would stop something, by a part of its
    /// title such as "sleep is running".
    func interruptionQuestion(containing text: String) -> XCUIElement {
        sheet.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .element(boundBy: 0)
    }
}

/// A command that runs until it is stopped, for the tests about closing a busy shell.
struct LongRunningJob {
    /// What to type in a shell of the repository: letters and a space only.
    static let command = "sh longjob"

    let repository: FixtureRepository

    var started: URL { repository.url.appending(path: "longjob-started") }

    /// The pid of the `sleep` the job became, nil before it has started.
    var pid: Int32? {
        guard FileManager.default.fileExists(atPath: started.path),
              let text = try? String(contentsOf: repository.url.appending(path: "longjob-pid"), encoding: .utf8)
        else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isRunning: Bool { pid.map { kill($0, 0) == 0 } ?? false }
}

extension FixtureRepository {
    /// Writes the script `LongRunningJob.command` runs. It becomes `sleep` in place, so the app
    /// sees the same process the script wrote down, and names it as "sleep" when it asks.
    func writeLongRunningJob() throws -> LongRunningJob {
        try write("longjob", """
            echo $$ > longjob-pid
            touch longjob-started
            exec sleep 600

            """)
        return LongRunningJob(repository: self)
    }

    /// A workspace with this repository's main checkout split into panes, each holding the given
    /// sessions in order, as if the user had split them and dragged the dividers to `widthShares`.
    func splitWorkspace(
        panes: [[Session]],
        widthShares: [Double]? = nil,
        focusedPane: Int = 0,
        linkedWorktrees: [Worktree] = []
    ) -> Workspace {
        var main = Worktree(path: url, branch: "main", isMain: true, sessions: panes.flatMap(\.self))
        main.panes = panes.enumerated().map { index, sessions in
            Pane(tabs: sessions.map { Tab(content: .session($0.id)) }, widthShare: widthShares?[index])
        }
        main.focusedPaneID = main.panes[focusedPane].id
        let project = Project(name: url.lastPathComponent, folderURL: url, worktrees: [main] + linkedWorktrees)
        var workspace = Workspace()
        workspace.addProject(project, to: workspace.islands[0].id)
        workspace.selectWorktree(main.id)
        return workspace
    }
}
