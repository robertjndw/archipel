import AgentKit
import Foundation
import Testing

struct AgentDefinitionTests {
    let sessionID = UUID(uuidString: "6B1D8B39-2C7C-4F5E-9A3E-0F4C3B2A1D00")!
    let hook = URL(fileURLWithPath: "/Applications/Archipel's Copy.app/Contents/Helpers/archipel-hook")
    let socket = URL(fileURLWithPath: "/tmp/archipel.sock")

    func context(agentSessionID: String?) -> LaunchContext {
        LaunchContext(
            archipelSessionID: sessionID,
            agentSessionID: agentSessionID,
            hookExecutableURL: hook,
            socketURL: socket
        )
    }

    func expectHookEnvironment(_ command: LaunchCommand) {
        #expect(command.environment["ARCHIPEL_SESSION_ID"] == sessionID.uuidString)
        #expect(command.environment["ARCHIPEL_SOCKET"] == "/tmp/archipel.sock")
    }

    func settings(after flag: String, in arguments: [String]) throws -> [String: Any] {
        let index = try #require(arguments.firstIndex(of: flag))
        let json = try #require(arguments.indices.contains(index + 1) ? arguments[index + 1] : nil)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func registry() {
        #expect(AgentDefinition.builtIns.map(\.id) == ["claude", "codex", "shell"])
        #expect(AgentDefinition.builtIn(id: "codex")?.executableName == "codex")
        #expect(AgentDefinition.builtIn(id: "nope") == nil)
    }

    @Test func claudeFreshStart() throws {
        let agentID = "0F8E3C2A-5B6D-4E7F-8091-A2B3C4D5E6F7"
        let command = AgentDefinition.claude.launchCommand(for: context(agentSessionID: agentID))
        #expect(command.executable == "claude")
        #expect(Array(command.arguments.prefix(2)) == ["--session-id", agentID])
        expectHookEnvironment(command)

        let hooks = try #require(try settings(after: "--settings", in: command.arguments)["hooks"] as? [String: Any])
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"] {
            let groups = try #require(hooks[event] as? [[String: Any]], "missing \(event)")
            let handler = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)
            #expect(handler["type"] as? String == "command")
            #expect(handler["command"] as? String == ShellQuoting.quote(hook.path))
        }
    }

    @Test func claudeStatusLineGoesThroughTheHook() throws {
        let command = AgentDefinition.claude.launchCommand(for: context(agentSessionID: nil))
        let statusLine = try #require(try settings(after: "--settings", in: command.arguments)["statusLine"] as? [String: Any])
        #expect(statusLine["type"] as? String == "command")
        #expect(statusLine["command"] as? String == ShellQuoting.quote(hook.path) + " statusline")
    }

    @Test func claudeResume() throws {
        let agentID = "0F8E3C2A-5B6D-4E7F-8091-A2B3C4D5E6F7"
        let command = try #require(AgentDefinition.claude.resumeCommand(for: context(agentSessionID: agentID)))
        #expect(Array(command.arguments.prefix(2)) == ["--resume", agentID])
        #expect(!command.arguments.contains("--session-id"))
        _ = try settings(after: "--settings", in: command.arguments)
        expectHookEnvironment(command)

        #expect(AgentDefinition.claude.resumeCommand(for: context(agentSessionID: nil)) == nil)
    }

    @Test func codexFreshAndResume() throws {
        let fresh = AgentDefinition.codex.launchCommand(for: context(agentSessionID: nil))
        #expect(fresh.executable == "codex")
        #expect(fresh.arguments == [
            "-c", #"notify=["/Applications/Archipel's Copy.app/Contents/Helpers/archipel-hook", "codex-notify"]"#,
            "-c", "tui.notifications=[\"approval-requested\"]",
            "-c", #"tui.notification_method="osc9""#,
            "-c", #"tui.notification_condition="always""#,
        ])
        #expect(!fresh.arguments.contains { $0.contains("hook-trust") })
        expectHookEnvironment(fresh)

        let resumed = try #require(AgentDefinition.codex.resumeCommand(for: context(agentSessionID: "thread-1")))
        #expect(resumed.arguments.first == "resume")
        #expect(resumed.arguments.last == "thread-1")
        #expect(Array(resumed.arguments.dropFirst().dropLast()) == fresh.arguments)
    }

    @Test func shell() {
        let command = AgentDefinition.shell.launchCommand(for: context(agentSessionID: nil))
        #expect(command.executable.hasPrefix("/"))
        #expect(command.arguments == ["-l"])
        expectHookEnvironment(command)
        #expect(AgentDefinition.shell.resumeCommand(for: context(agentSessionID: "x")) == nil)
    }

    @Test func shellCommandLineQuoting() {
        let command = LaunchCommand(
            executable: "/Applications/My App.app/bin/tool",
            arguments: ["--flag", "it's", "", "plain-value_1.0", #"{"a": "$HOME"}"#],
            environment: [:]
        )
        #expect(command.shellCommandLine
            == #"'/Applications/My App.app/bin/tool' --flag 'it'\''s' '' plain-value_1.0 '{"a": "$HOME"}'"#)
    }

    @Test func shellCommandLineRoundTripsThroughShell() throws {
        let command = AgentDefinition.claude.launchCommand(
            for: context(agentSessionID: "0F8E3C2A-5B6D-4E7F-8091-A2B3C4D5E6F7")
        )
        let printer = LaunchCommand(executable: "/usr/bin/printf", arguments: ["%s\\0"] + command.arguments, environment: [:])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", printer.shellCommandLine]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let words = data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        #expect(words == command.arguments)
    }

    @Test func modelArgumentsLeaveExtraArgumentsAloneWithoutAModel() {
        #expect(AgentDefinition.arguments(["--model", "opus", "--verbose"], model: nil) == ["--model", "opus", "--verbose"])
    }

    @Test func modelArgumentsReplaceTheUsersModel() {
        #expect(AgentDefinition.arguments(["--model", "opus", "--verbose"], model: "fable") == ["--verbose", "--model", "fable"])
        #expect(AgentDefinition.arguments(["--model=opus", "--verbose"], model: "fable") == ["--verbose", "--model", "fable"])
        #expect(AgentDefinition.arguments([], model: "fable") == ["--model", "fable"])
        // A trailing --model with no value is dropped too.
        #expect(AgentDefinition.arguments(["--verbose", "--model"], model: "fable") == ["--verbose", "--model", "fable"])
    }

    @Test func modelIsReadFromArguments() {
        #expect(AgentDefinition.model(in: ["--verbose"]) == nil)
        #expect(AgentDefinition.model(in: ["--model", "opus", "--verbose"]) == "opus")
        #expect(AgentDefinition.model(in: ["--model=haiku"]) == "haiku")
        #expect(AgentDefinition.model(in: ["--model", "opus", "--model=fable"]) == "fable")
        #expect(AgentDefinition.model(in: ["--model"]) == nil)
        #expect(AgentDefinition.model(in: ["--model="]) == nil)
    }

    @Test func onlyClaudeListsModels() {
        #expect(!AgentDefinition.claude.modelChoices.isEmpty)
        #expect(AgentDefinition.codex.modelChoices.isEmpty)
        #expect(AgentDefinition.shell.modelChoices.isEmpty)
    }
}
