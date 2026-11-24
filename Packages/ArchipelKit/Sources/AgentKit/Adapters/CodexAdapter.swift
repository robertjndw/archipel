import ArchipelCore
import Foundation

public struct CodexAdapter: AgentAdapter {
    public init() {}

    public let id = "codex"
    public let displayName = "Codex"
    public let symbolName = "openai.logo"
    public let executableName = "codex"
    /// What `archipel-hook codex-notify` sends.
    public static let notifySource = "codex"
    /// What the hook commands send. Trust must have been given before Codex runs them.
    public static let hooksSource = "codex-hooks"

    public let hookSources: Set<String> = [Self.notifySource, Self.hooksSource]
    /// Notify also fires for Codex's internal title thread, which hooks never do, so once hooks
    /// report a session its notify messages are noise.
    public var fallbackHookSources: Set<String> { [Self.notifySource] }

    public var acp: ACPSupport? {
        ACPSupport(registryID: "codex-acp", launch: .registry(cliExecutableVariable: nil), sharesConversationIDs: true)
    }

    public var capabilities: AgentCapabilities {
        AgentCapabilities(
            sessionID: .reportedByHook,
            // Until the user trusts the hooks, notify only reports finished turns, so start and
            // attention come from the terminal.
            lifecycle: .hooksOnceSeen,
            acceptsPrompts: true,
            answersApprovalsInTerminal: true,
            usage: .codexLogs,
            tracksSubagents: true,
            presetPlaceholder: "--model gpt-5",
            settingsSections: [.codexHooksStatus]
        )
    }

    public func launchCommand(for context: LaunchContext) -> LaunchCommand {
        LaunchCommand(
            executable: executableName,
            arguments: Self.overrides(context),
            environment: hookEnvironment(context)
        )
    }

    public func resumeCommand(for context: LaunchContext, agentSessionID: String) -> LaunchCommand? {
        LaunchCommand(
            executable: executableName,
            arguments: ["resume"] + Self.overrides(context) + [agentSessionID],
            environment: hookEnvironment(context)
        )
    }

    public func attentionReason(forTerminalNotification body: String) -> AttentionReason? {
        // The launch overrides restrict Codex to approval notifications.
        .permission
    }

    public func decodeHook(source: String, payload: [String: Any], receivedAt date: Date) -> DecodedHook? {
        if source == Self.hooksSource {
            return DecodedHook(
                event: Self.hookEvent(payload),
                agentSessionID: HookDecoder.nonEmptyString(payload["session_id"])
            )
        }
        // Field names follow the Codex `notify` documentation.
        let event: AgentEvent? = switch payload["type"] as? String {
        case "agent-turn-complete":
            .turnFinished(message: HookDecoder.nonEmptyString(payload["last-assistant-message"]))
        default:
            nil
        }
        return DecodedHook(event: event, agentSessionID: HookDecoder.nonEmptyString(payload["thread-id"]))
    }

    static func hookEvent(_ payload: [String: Any]) -> AgentEvent? {
        let agentID = HookDecoder.nonEmptyString(payload["agent_id"])
        switch payload["hook_event_name"] as? String {
        case "SessionStart":
            return .sessionStarted
        case "UserPromptSubmit":
            return .promptSubmitted
        case "PreToolUse", "PostToolUse":
            return agentID.map { .subagentActivity(id: $0) } ?? .activity
        case "PermissionRequest":
            return .attentionRequested(.permission, message: HookDecoder.nonEmptyString(payload["tool_name"]))
        case "Stop":
            return .turnFinished(message: HookDecoder.nonEmptyString(payload["last_assistant_message"]))
        case "SubagentStart":
            return agentID.map { .subagentStarted(id: $0) }
        case "SubagentStop":
            return agentID.map { .subagentFinished(id: $0) }
        default:
            // SessionEnd included: the terminal reports the process exit with its real code.
            return nil
        }
    }

    static func overrides(_ context: LaunchContext) -> [String] {
        notifyOverrides(hook: context.hookExecutableURL)
            + (context.stableHookURL.map(hookOverrides(link:)) ?? [])
    }

    static func notifyOverrides(hook: URL) -> [String] {
        [
            // Codex appends the JSON payload as one extra argv element after these.
            "-c", "notify=[\(tomlString(hook.path)), \"codex-notify\"]",
            // Turn completion already arrives through notify. Limiting the terminal
            // notifications to approvals lets the app read every one as "needs approval".
            "-c", "tui.notifications=[\"approval-requested\"]",
            "-c", "tui.notification_method=\"osc9\"",
            "-c", "tui.notification_condition=\"always\"",
        ]
    }

    /// Codex keys its trust of a hook by event, position and a hash of the handler, command
    /// included. Reordering these or changing the command makes the user trust them again.
    static let hookEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "Stop", "SubagentStart", "SubagentStop", "SessionEnd",
    ]

    /// Codex runs hook commands through a shell, so the path must be quoted.
    public static func hookCommand(link: URL) -> String {
        "\(ShellQuoting.quote(link.path)) event \(hooksSource)"
    }

    static func hookOverrides(link: URL) -> [String] {
        let command = tomlString(hookCommand(link: link))
        return hookEvents.flatMap { event in
            ["-c", "hooks.\(event)=[{hooks=[{type=\"command\",command=\(command)}]}]"]
        }
    }
}
