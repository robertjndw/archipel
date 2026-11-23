import AgentKit
import ArchipelCore
import Foundation
import Testing

struct ClaudeAdapterTests {
    let claude = ClaudeAdapter()
    let hook = LaunchFixture.hook

    @Test func freshStart() throws {
        let agentID = "0F8E3C2A-5B6D-4E7F-8091-A2B3C4D5E6F7"
        let command = claude.launchCommand(for: LaunchFixture.context(agentSessionID: agentID))
        #expect(command.executable == "claude")
        #expect(Array(command.arguments.prefix(2)) == ["--session-id", agentID])
        LaunchFixture.expectHookEnvironment(command)

        let hooks = try #require(try LaunchFixture.settings(after: "--settings", in: command.arguments)["hooks"] as? [String: Any])
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"] {
            let groups = try #require(hooks[event] as? [[String: Any]], "missing \(event)")
            let handler = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)
            #expect(handler["type"] as? String == "command")
            #expect(handler["command"] as? String == ShellQuoting.quote(hook.path))
        }
    }

    @Test func statusLineGoesThroughTheHook() throws {
        let command = claude.launchCommand(for: LaunchFixture.context(agentSessionID: nil))
        let statusLine = try #require(try LaunchFixture.settings(after: "--settings", in: command.arguments)["statusLine"] as? [String: Any])
        #expect(statusLine["type"] as? String == "command")
        #expect(statusLine["command"] as? String == ShellQuoting.quote(hook.path) + " statusline")
    }

    @Test func onlyClaudeLaunchesCarryTheUserHooksFlag() throws {
        let variable = ClaudeUserHooks.launchedByArchipelVariable
        let fresh = claude.launchCommand(for: LaunchFixture.context(agentSessionID: nil))
        let resumed = try #require(claude.resumeCommand(for: LaunchFixture.context(agentSessionID: "id")))
        #expect(fresh.environment[variable] == "settings")
        #expect(resumed.environment[variable] == "settings")
        LaunchFixture.expectHookEnvironment(fresh)

        #expect(ShellAdapter().launchCommand(for: LaunchFixture.context(agentSessionID: nil)).environment[variable] == nil)
        #expect(CodexAdapter().launchCommand(for: LaunchFixture.context(agentSessionID: nil)).environment[variable] == nil)
        let codexResume = try #require(CodexAdapter().resumeCommand(for: LaunchFixture.context(agentSessionID: "t")))
        #expect(codexResume.environment[variable] == nil)
    }

    @Test func resume() throws {
        let agentID = "0F8E3C2A-5B6D-4E7F-8091-A2B3C4D5E6F7"
        let command = try #require(claude.resumeCommand(for: LaunchFixture.context(agentSessionID: agentID)))
        #expect(Array(command.arguments.prefix(2)) == ["--resume", agentID])
        #expect(!command.arguments.contains("--session-id"))
        _ = try LaunchFixture.settings(after: "--settings", in: command.arguments)
        LaunchFixture.expectHookEnvironment(command)

        #expect(claude.resumeCommand(for: LaunchFixture.context(agentSessionID: nil)) == nil)
    }

    @Test func capabilities() {
        let capabilities = claude.capabilities
        #expect(capabilities.sessionID == .presetByApp)
        #expect(capabilities.lifecycle == .hooks)
        #expect(capabilities.reportsLifecycleThroughHooks)
        #expect(capabilities.acceptsPrompts)
        #expect(capabilities.usage == .claudeStatusLine)
        #expect(capabilities.presetPlaceholder == "--model opus")
        #expect(capabilities.settingsSections == [.claudeShellHooks])
        #expect(claude.hookSources == ["claude", "claude-statusline"])
    }

    @Test func terminalNotificationsOfAHandStartedClaude() {
        // A hand-started Claude prints "waiting for input" after every turn, so it is skipped.
        for body in ["Claude needs your permission to use Bash", "Claude is waiting for your input", "something else"] {
            #expect(claude.attentionReason(forTerminalNotification: body) == ClaudeTerminalNotification.reason(forBody: body))
        }
    }

    @Test func commandLineRoundTripsThroughShell() throws {
        let command = claude.launchCommand(
            for: LaunchFixture.context(agentSessionID: "0F8E3C2A-5B6D-4E7F-8091-A2B3C4D5E6F7")
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
}
