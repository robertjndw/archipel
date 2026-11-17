import ArchipelCore
import XCTest

/// The path an agent's status takes into the window: the app starts the agent with its hook helper
/// configured, the agent runs the helper on every event, and the helper reports to the app's socket.
/// A script stands in for Claude Code here; everything after it is the real thing.
final class AgentTests: ArchipelUITestCase {
    private struct AgentLaunch {
        var sessionID = ""
        var socket = ""
        var workingDirectory = ""
        var arguments: [String] = []

        init(contentsOf record: URL) throws {
            for line in try String(contentsOf: record, encoding: .utf8).split(separator: "\n") {
                guard let separator = line.firstIndex(of: "=") else { continue }
                let value = String(line[line.index(after: separator)...])
                switch line[..<separator] {
                case "session": sessionID = value
                case "socket": socket = value
                case "cwd": workingDirectory = value
                case "argument": arguments.append(value)
                default: break
                }
            }
        }
    }

    /// The status bar's summary of every session, which is also what VoiceOver reads there.
    private var agentsSummary: XCUIElement { mainWindow.buttons["Agents"] }
    private var agentsStatus: String { agentsSummary.value as? String ?? "" }

    /// Runs the hook helper the way Claude Code does: the event as JSON on standard input.
    private func sendHook(_ event: [String: Any], hook: String, launch: AgentLaunch) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hook)
        var environment = ProcessInfo.processInfo.environment
        environment["ARCHIPEL_SESSION_ID"] = launch.sessionID
        environment["ARCHIPEL_SOCKET"] = launch.socket
        environment["HOME"] = sandbox.home.path
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: event))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "The hook helper must never fail the agent's hook.")
    }

    func testAgentStatusReachesTheWindowThroughTheHook() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let record = try sandbox.installAgentStub(named: "claude")
        try launch(with: repository.workspace())

        assertExists(agentsSummary, "The status bar should show the agents summary.")
        XCTAssertEqual(agentsStatus, "None working")

        mainWindow.buttons["Claude Code"].click()
        assertExists(tab("Claude Code"), "Starting the agent should open its tab.")
        waitUntil("the agent was started") { FileManager.default.fileExists(atPath: record.path) }
        var launch = try AgentLaunch(contentsOf: record)
        waitUntil("the agent's launch is written down in full") {
            launch = try AgentLaunch(contentsOf: record)
            return !launch.sessionID.isEmpty && launch.arguments.contains("--settings")
        }

        // What the app handed the agent: where it runs, which session it is, and the helper to call.
        // The terminal is handed the folder with a trailing slash.
        XCTAssertEqual(launch.workingDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                       repository.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        XCTAssertEqual(launch.socket, sandbox.support.appending(path: "hook.sock").path)
        waitUntil("the session is saved under the id the agent was given") {
            try sandbox.savedWorkspace().allSessions.map(\.id.uuidString) == [launch.sessionID]
        }
        let settingsIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "--settings"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(launch.arguments[settingsIndex + 1].utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        // Quoted for the shell the agent runs it in; these paths need no quotes.
        let hook = try XCTUnwrap(stop["command"] as? String)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: hook), "The agent was pointed at a hook helper that is not there: \(hook)")
        let conversation = launch.arguments[try XCTUnwrap(launch.arguments.firstIndex(of: "--session-id")) + 1]

        // Booting counts as working until the agent reports that it is up and waiting for a prompt.
        XCTAssertEqual(agentsStatus, "1 agent working")
        try sendHook(["hook_event_name": "SessionStart", "session_id": conversation], hook: hook, launch: launch)
        waitUntil("the window shows the agent idle at its prompt") { self.agentsStatus == "None working" }

        try sendHook(["hook_event_name": "UserPromptSubmit", "session_id": conversation], hook: hook, launch: launch)
        waitUntil("the window shows the agent working") { self.agentsStatus.contains("1 agent working") }
        // A first turn is what makes the conversation resumable, so its id is kept from here on.
        waitUntil("the conversation id is saved") {
            try sandbox.savedWorkspace().allSessions.first?.agentSessionID == conversation
        }

        try sendHook(["hook_event_name": "PermissionRequest", "session_id": conversation, "tool_name": "Bash"], hook: hook, launch: launch)
        waitUntil("the window shows the agent waiting for the user") { self.agentsStatus.contains("1 waiting for you") }
        assertExists(mainWindow.images["Needs your approval"], "The sidebar row should say what the agent is waiting for.")
        assertExists(mainWindow.staticTexts["Bash"], "The sidebar row should name the tool that needs approval.")

        try sendHook(["hook_event_name": "PostToolUse", "session_id": conversation], hook: hook, launch: launch)
        waitUntil("the window shows the agent working again") {
            self.agentsStatus.contains("1 agent working") && !self.agentsStatus.contains("waiting")
        }

        try sendHook(["hook_event_name": "Stop", "session_id": conversation, "last_assistant_message": "Done."], hook: hook, launch: launch)
        waitUntil("the window shows the turn has ended") {
            !self.agentsStatus.contains("working") && !self.agentsStatus.contains("waiting")
        }
    }

    func testAHookForAnUnknownSessionIsIgnored() throws {
        let repository = try sandbox.makeRepository(named: "fixture")
        let record = try sandbox.installAgentStub(named: "claude")
        try launch(with: repository.workspace())

        mainWindow.buttons["Claude Code"].click()
        waitUntil("the agent was started") { try !AgentLaunch(contentsOf: record).socket.isEmpty }
        var launch = try AgentLaunch(contentsOf: record)
        let hook = hookHelper.path
        let realSession = launch.sessionID

        // A session that was closed meanwhile, or another app's: the event has nowhere to go.
        launch.sessionID = UUID().uuidString
        try sendHook(["hook_event_name": "UserPromptSubmit", "session_id": "stranger"], hook: hook, launch: launch)
        // The real session's event is sent after it on the same socket, so once that one shows,
        // the stray one has been handled as well.
        launch.sessionID = realSession
        try sendHook(["hook_event_name": "PermissionRequest", "session_id": "known", "tool_name": "Bash"], hook: hook, launch: launch)

        waitUntil("the real session's event shows") { self.agentsStatus.contains("1 waiting for you") }
        XCTAssertFalse(agentsStatus.contains("working"), "The stray event must not have been applied to the session.")
    }
}
