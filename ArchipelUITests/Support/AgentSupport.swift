import ArchipelCore
import Foundation
import XCTest

/// How a stand-in agent was started, read back from what the stub wrote down.
struct AgentLaunch {
    var sessionID = ""
    var socket = ""
    var workingDirectory = ""
    var arguments: [String] = []

    /// The record of `Sandbox.installAgentStub(named:)`, which holds the latest launch only.
    init(contentsOf record: URL) throws {
        try self.init(lines: String(contentsOf: record, encoding: .utf8).split(separator: "\n"))
    }

    private init(lines: some Sequence<Substring>) {
        for line in lines {
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

    /// Every launch in the record of `Sandbox.installRecordingAgentStub(named:)`, oldest first. A
    /// launch only counts once its closing line is there: the stub writes it a line at a time, and
    /// a half-written one would look like a launch without arguments.
    static func all(in record: URL) throws -> [AgentLaunch] {
        guard FileManager.default.fileExists(atPath: record.path) else { return [] }
        var launches: [AgentLaunch] = []
        var lines: [Substring] = []
        for line in try String(contentsOf: record, encoding: .utf8).split(separator: "\n") {
            if line == Sandbox.endOfLaunch {
                launches.append(AgentLaunch(lines: lines))
                lines = []
            } else {
                lines.append(line)
            }
        }
        return launches
    }

    /// The value that follows a flag such as `--session-id`, or nil when the flag was not passed.
    func argument(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// What follows each `-c`, the way Codex takes configuration overrides.
    var configOverrides: [String] {
        arguments.indices.dropLast().filter { arguments[$0] == "-c" }.map { arguments[$0 + 1] }
    }

    /// The command Codex was told to run when a turn ends. The override is a TOML array of strings,
    /// which for plain paths like the sandbox's is valid JSON as well.
    var codexNotifyCommand: [String]? {
        let prefix = "notify="
        guard let override = configOverrides.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(override.dropFirst(prefix.count).utf8)) as? [String]
    }

    /// The terminal is handed the folder with a trailing slash, and `URL.path` has none.
    func ran(in folder: URL) -> Bool {
        let slash = CharacterSet(charactersIn: "/")
        return workingDirectory.trimmingCharacters(in: slash) == folder.path.trimmingCharacters(in: slash)
    }
}

/// Where a recording stub writes down its launches and what the app typed into it.
struct AgentStubRecord {
    let launches: URL
    let input: URL
}

extension Sandbox {
    fileprivate static let endOfLaunch = "end-of-launch"

    /// Like `installAgentStub(named:)`, but each launch is added to the record instead of replacing
    /// it, so a test can tell a restart or a relaunch apart from the launch before it. Instead of
    /// sleeping, the stub then copies whatever arrives on its terminal to `input`: that is where
    /// text the app pastes into an agent ends up.
    func installRecordingAgentStub(named name: String) throws -> AgentStubRecord {
        let record = AgentStubRecord(
            launches: root.appending(path: "\(name)-launches.txt"),
            input: root.appending(path: "\(name)-input.txt")
        )
        // Without -icanon the terminal would hold back a last line that has no newline, and pasted
        // text never ends in one, since the user is meant to read it before pressing Return.
        let script = """
            #!/bin/sh
            {
              echo "session=$ARCHIPEL_SESSION_ID"
              echo "socket=$ARCHIPEL_SOCKET"
              echo "cwd=$PWD"
              for argument in "$@"; do echo "argument=$argument"; done
              echo "\(Self.endOfLaunch)"
            } >> '\(record.launches.path)'
            stty -icanon 2>/dev/null
            exec cat >> '\(record.input.path)'

            """
        let executable = bin.appending(path: name)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return record
    }
}

/// A stub agent that asks for the user on demand.
struct AskingAgentStub {
    fileprivate let trigger: URL

    /// Makes the stub send the terminal notification Codex sends when it wants an approval.
    func ask() throws {
        try Data().write(to: trigger)
    }
}

extension Sandbox {
    /// An agent that stays quiet until `ask()`, then notifies through the terminal (OSC 9) and
    /// goes on waiting, as Codex does at an approval prompt.
    func installAskingAgentStub(named name: String) throws -> AskingAgentStub {
        let stub = AskingAgentStub(trigger: root.appending(path: "\(name)-ask"))
        let script = """
            #!/bin/sh
            while [ ! -e '\(stub.trigger.path)' ]; do sleep 0.2; done
            printf '\\033]9;Approval requested\\007'
            while :; do sleep 1; done

            """
        let executable = bin.appending(path: name)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return stub
    }
}

extension Session {
    static func claude(_ title: String = "Claude Code") -> Session {
        Session(title: title, agent: .claude)
    }
}

extension ArchipelUITestCase {
    /// The status bar's summary of every session, which is also what VoiceOver reads there.
    var agentsSummary: XCUIElement { mainWindow.buttons["Agents"] }
    var agentsStatus: String { agentsSummary.value as? String ?? "" }

    /// The socket the app listens on for hook events, as it hands it to every agent.
    var hookSocket: String { sandbox.support.appending(path: "hook.sock").path }

    /// Waits until a recording stub has been started `count` times and returns the newest launch.
    /// Fails when it was started more often, which would mean a launch the test did not ask for.
    func waitForLaunch(
        _ count: Int,
        recordedIn record: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AgentLaunch {
        waitUntil("the agent was started \(count == 1 ? "once" : "\(count) times")", file: file, line: line) {
            try AgentLaunch.all(in: record).count >= count
        }
        let launches = try AgentLaunch.all(in: record)
        XCTAssertEqual(launches.count, count, "The agent was started more often than the test asked for.", file: file, line: line)
        return try XCTUnwrap(launches.last, file: file, line: line)
    }

    /// Runs the hook helper the way Claude Code does: the event as JSON on standard input.
    func sendHook(_ event: [String: Any], hook: String, launch: AgentLaunch, file: StaticString = #filePath, line: UInt = #line) throws {
        try sendHook(event, hook: hook, sessionID: launch.sessionID, socket: launch.socket, file: file, line: line)
    }

    /// For a session whose agent never ran: the app keeps the state of every session in the
    /// workspace, so a hook reaches it all the same.
    func sendHook(
        _ event: [String: Any],
        hook: String,
        sessionID: String,
        socket: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try runHookHelper(hook, arguments: [], input: JSONSerialization.data(withJSONObject: event),
                          sessionID: sessionID, socket: socket, file: file, line: line)
    }

    /// Runs Codex's `notify` command the way Codex does: the configured command with the event as
    /// one more argument at the end.
    func sendCodexNotification(_ event: [String: Any], command: [String], launch: AgentLaunch, file: StaticString = #filePath, line: UInt = #line) throws {
        let executable = try XCTUnwrap(command.first, "The notify command is empty.", file: file, line: line)
        let payload = try String(decoding: JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        try runHookHelper(executable, arguments: Array(command.dropFirst()) + [payload], input: nil,
                          sessionID: launch.sessionID, socket: launch.socket, file: file, line: line)
    }

    private func runHookHelper(
        _ executable: String,
        arguments: [String],
        input: Data?,
        sessionID: String,
        socket: String,
        file: StaticString,
        line: UInt
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // What the agent passes on to its hooks: the variables the app started it with.
        var environment = ProcessInfo.processInfo.environment
        environment["ARCHIPEL_SESSION_ID"] = sessionID
        environment["ARCHIPEL_SOCKET"] = socket
        environment["HOME"] = sandbox.home.path
        process.environment = environment
        let pipe = Pipe()
        if input == nil {
            process.standardInput = FileHandle.nullDevice
        } else {
            process.standardInput = pipe
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let input {
            try pipe.fileHandleForWriting.write(contentsOf: input)
            try pipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "The hook helper must never fail the agent's hook.", file: file, line: line)
    }
}
