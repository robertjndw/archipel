import AgentKit
import Foundation
import Testing

struct CodexAdapterTests {
    let codex = CodexAdapter()

    @Test func freshAndResume() throws {
        let fresh = codex.launchCommand(for: LaunchFixture.context(agentSessionID: nil))
        #expect(fresh.executable == "codex")
        #expect(fresh.arguments == [
            "-c", #"notify=["/Applications/Archipel's Copy.app/Contents/Helpers/archipel-hook", "codex-notify"]"#,
            "-c", "tui.notifications=[\"approval-requested\"]",
            "-c", #"tui.notification_method="osc9""#,
            "-c", #"tui.notification_condition="always""#,
        ] + Self.hookArguments)
        #expect(!fresh.arguments.contains { $0.contains("hook-trust") })
        LaunchFixture.expectHookEnvironment(fresh)

        let thread = "0199a213-81c0-7800-8aa1-bbab2a035a53"
        let resumed = try #require(codex.resumeCommand(for: LaunchFixture.context(agentSessionID: thread)))
        #expect(resumed.arguments.first == "resume")
        #expect(resumed.arguments.last == thread)
        #expect(Array(resumed.arguments.dropFirst().dropLast()) == fresh.arguments)
    }

    /// The command is shell quoted first and TOML escaped second, so the space in the path is
    /// quoted for the shell and the whole command is one TOML string.
    static let hookCommand = "\"'/Users/me/Library/Application Support/Archipel/bin/archipel-hook' event codex-hooks\""

    static let hookEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "Stop", "SubagentStart", "SubagentStop", "SessionEnd",
    ]

    static var hookArguments: [String] {
        hookEvents.flatMap { ["-c", "hooks.\($0)=[{hooks=[{type=\"command\",command=\(hookCommand)}]}]"] }
    }

    @Test func hookOverridesComeInAFixedOrder() {
        let command = codex.launchCommand(for: LaunchFixture.context(agentSessionID: nil))
        let events = command.arguments.compactMap { argument -> String? in
            guard argument.hasPrefix("hooks.") else { return nil }
            return String(argument.dropFirst("hooks.".count).prefix { $0 != "=" })
        }
        #expect(events == Self.hookEvents)
    }

    @Test func hookCommandIgnoresTheBundlePath() {
        let command = codex.launchCommand(for: LaunchFixture.context(agentSessionID: nil))
        #expect(!command.arguments.filter { $0.hasPrefix("hooks.") }.contains { $0.contains("Archipel's Copy") })
    }

    @Test func withoutAStableLinkOnlyTheFallbackIsInstalled() {
        let command = codex.launchCommand(for: LaunchFixture.context(agentSessionID: nil, stableHook: nil))
        #expect(!command.arguments.contains { $0.hasPrefix("hooks.") })
        #expect(command.arguments.count == 8)
    }

    @Test func chatSupport() throws {
        let acp = try #require(codex.acp)
        #expect(acp.registryID == "codex-acp")
        #expect(acp.launch == .registry(cliExecutableVariable: nil))
        #expect(acp.sharesConversationIDs)
        #expect(acp.environment.isEmpty)
    }

    @Test func capabilities() {
        let capabilities = codex.capabilities
        #expect(capabilities.sessionID == .reportedByHook)
        #expect(capabilities.lifecycle == .hooksOnceSeen)
        #expect(!capabilities.reportsLifecycleThroughHooks)
        #expect(capabilities.acceptsPrompts)
        #expect(capabilities.usage == .codexLogs)
        #expect(capabilities.usage?.canRefreshOnDemand == true)
        #expect(capabilities.presetPlaceholder == "--model gpt-5")
        #expect(capabilities.settingsSections == [.codexHooksStatus])
        #expect(capabilities.tracksSubagents)
        #expect(codex.hookSources == ["codex", "codex-hooks"])
        #expect(codex.fallbackHookSources == ["codex"])
    }

    @Test func everyTerminalNotificationIsAnApproval() {
        #expect(codex.attentionReason(forTerminalNotification: "Approval requested: rm -rf build") == .permission)
        #expect(codex.attentionReason(forTerminalNotification: "") == .permission)
    }
}
