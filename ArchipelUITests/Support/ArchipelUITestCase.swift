import ArchipelCore
import XCTest

/// Base class of every UI test. Each test gets a sandbox of its own and launches the app against
/// it, so tests can run alone and in any order.
@MainActor
class ArchipelUITestCase: XCTestCase {
    private(set) var sandbox: Sandbox!
    private(set) var app: XCUIApplication!

    /// How long a state the app reaches by itself may take: a git call, a sheet animating in, a
    /// save. Generous, because a busy machine only makes a passing test slower.
    static let timeout: TimeInterval = 15

    override func setUp() async throws {
        continueAfterFailure = false
        sandbox = try Sandbox()
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning {
            // What the windows looked like when the test gave up. xcodebuild's plain output has
            // nothing else to go on, and that output is all a CI log keeps.
            if let run = testRun, run.totalFailureCount > 0 {
                for window in app.windows.allElementsBoundByIndex { print("Window at failure:\n\(window.debugDescription)") }
            }
            app.terminate()
        }
        app = nil
        sandbox?.remove()
        sandbox = nil
    }

    // MARK: Launching

    struct UnsafeAppUnderTest: Error, CustomStringConvertible {
        let app: URL
        let bundleID: String

        var description: String {
            """
            Refusing to launch \(app.path) with the bundle id "\(bundleID)". Run the UI tests through \
            the ArchipelUITests scheme (./scripts/ui-tests.sh), which builds the app with a bundle id \
            that no other copy of Archipel uses.
            """
        }
    }

    /// The app this bundle was built with, next to the test runner in the build products.
    private static let builtApp: (url: URL, bundleID: String) = {
        // <products>/ArchipelUITests-Runner.app/Contents/PlugIns/ArchipelUITests.xctest
        let products = Bundle(for: ArchipelUITestCase.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = products.appending(path: "Archipel.app", directoryHint: .isDirectory)
        return (url, Bundle(url: url)?.bundleIdentifier ?? "")
    }()

    /// The helper the app tells agents to run on their hook events.
    var hookHelper: URL { Self.builtApp.url.appending(path: "Contents/Helpers/archipel-hook") }

    /// Starts the app with nothing of the previous launch but the sandbox. Pass `keepingState` to
    /// launch it again the way a user reopening the app would find it.
    @discardableResult
    func launch(keepingState: Bool = false) throws -> XCUIApplication {
        let built = Self.builtApp
        // XCUIApplication.launch() terminates every running app with the same bundle identifier.
        // Only the UITests configuration gives the app an id of its own; built any other way this
        // would quit the Archipel the developer is working in, sessions included.
        guard built.bundleID.hasSuffix(".uitests") else { throw UnsafeAppUnderTest(app: built.url, bundleID: built.bundleID) }
        if let app, app.state != .notRunning { app.terminate() }
        if !keepingState {
            // The window layout and the last inspector tab live in the defaults of the test build.
            UserDefaults.standard.removePersistentDomain(forName: built.bundleID)
        }

        let app = XCUIApplication(url: built.url)
        app.launchEnvironment = [
            "ARCHIPEL_SUPPORT_DIR": sandbox.support.path,
            // For what the app starts, not the app itself: the shell of a session and the one asked
            // for the PATH, git, and the agents' own configuration lookups. None of them may read
            // the dotfiles of whoever runs the tests.
            "HOME": sandbox.home.path,
            "SHELL": "/bin/sh",
            "ENV": "",
            "XDG_CONFIG_HOME": sandbox.home.appending(path: ".config").path,
            "CODEX_HOME": sandbox.home.appending(path: ".codex").path,
            "CLAUDE_CONFIG_DIR": sandbox.home.appending(path: ".claude").path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        app.launchArguments = [
            // No "reopen windows?" dialog after a test that ended with the app being killed.
            "-ApplePersistenceIgnoreState", "YES",
            // Settings the tests rely on, given as arguments so they win over anything stored.
            // Without the first, new worktrees would land in ~/.archipel.
            "-settings.worktreesRoot", sandbox.worktreesRoot.path,
            // The default would be whichever real agent is installed on this machine.
            "-settings.defaultAgentID", "shell",
            "-settings.showsMenuBarExtra", "NO",
            "-settings.fetchesAutomatically", "NO",
            "-settings.showsPullRequests", "NO",
            "-settings.notifiesWhenAttentionNeeded", "NO",
            "-settings.notifiesWhenFinished", "NO",
            "-settings.notifiesWhenExited", "NO",
            "-settings.showsDockBadge", "NO",
            "-settings.confirmsQuitWhileWorking", "NO",
        ]
        app.launch()
        self.app = app
        assertExists(mainWindow, "The main window did not open.")
        return app
    }

    /// Seeds the workspace file, then launches.
    @discardableResult
    func launch(with workspace: Workspace) throws -> XCUIApplication {
        try sandbox.seed(workspace)
        return try launch()
    }

    /// Ends the app the way the tests end it between two launches. The workspace is saved a moment
    /// after each change, so callers wait for the file to say what they expect before this.
    func quit() {
        app.terminate()
    }

    // MARK: Common elements

    /// By identifier: the title follows the selected worktree.
    var mainWindow: XCUIElement { app.windows.matching(identifier: "main").element(boundBy: 0) }

    /// The title names the selected worktree as "project - branch", which makes it the quickest
    /// way to tell which one the window shows.
    func mainWindow(titled title: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier == %@ AND title == %@", "main", title)).element(boundBy: 0)
    }

    func menuItem(_ menu: String, _ item: String) -> XCUIElement {
        app.menuBars.menuBarItems[menu].menuItems[item]
    }

    /// Picks a command from the menu bar. Menus are where every action of the app is reachable
    /// without depending on hover states or the layout of the window.
    func chooseMenu(_ menu: String, _ item: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.menuBars.menuBarItems[menu]
        assertExists(bar, "No \(menu) menu.", file: file, line: line)
        bar.click()
        let entry = bar.menuItems[item]
        assertExists(entry, "No \(item) in the \(menu) menu.", file: file, line: line)
        XCTAssertTrue(entry.isEnabled, "\(menu) > \(item) is disabled.", file: file, line: line)
        entry.click()
    }

    /// Picks an item from the context menu that a right click just opened. The menu bar holds
    /// items of the same name, so the one to click is the one that is on screen.
    func chooseContextMenu(_ item: String, file: StaticString = #filePath, line: UInt = #line) {
        let candidates = app.menuItems.matching(NSPredicate(format: "title == %@", item))
        var shown: XCUIElement?
        waitUntil("the context menu shows \(item)", file: file, line: line) {
            shown = candidates.allElementsBoundByIndex.first(where: \.isHittable)
            return shown != nil
        }
        shown?.click()
    }

    // MARK: Waiting

    /// Polls for something outside the app's interface, such as the state of a repository or the
    /// workspace file. Fails the test when it does not come true in time.
    func waitUntil(
        _ what: String,
        timeout: TimeInterval = ArchipelUITestCase.timeout,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () throws -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: (any Error)?
        repeat {
            do {
                if try condition() { return }
                lastError = nil
            } catch {
                lastError = error
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        let reason = lastError.map { " Last error: \($0)" } ?? ""
        XCTFail("Timed out waiting until \(what).\(reason)", file: file, line: line)
    }

    func assertExists(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        // Asked directly first: waitForExistence only looks after a second has passed.
        if element.exists { return }
        XCTAssertTrue(element.waitForExistence(timeout: Self.timeout), message, file: file, line: line)
    }

    func assertGone(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if !element.exists { return }
        XCTAssertTrue(element.waitForNonExistence(timeout: Self.timeout), message, file: file, line: line)
    }
}
