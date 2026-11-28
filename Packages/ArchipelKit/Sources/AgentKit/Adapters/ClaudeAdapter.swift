import ArchipelCore
import Foundation

public struct ClaudeAdapter: AgentAdapter {
    /// Not a hook: Claude's status line, which runs on every redraw and carries no event, only the
    /// limits and the context window.
    public static let statusLineSource = "claude-statusline"

    public init() {}

    public let id = "claude"
    public let displayName = "Claude Code"
    public let symbolName = "claude.logo"
    public let executableName = "claude"
    public let hookSources: Set<String> = ["claude", Self.statusLineSource]

    public var acp: ACPSupport? {
        ACPSupport(
            registryID: "claude-acp",
            launch: .registry(cliExecutableVariable: "CLAUDE_CODE_EXECUTABLE"),
            sharesConversationIDs: true,
            environment: Self.launchedByArchipelEnvironment,
            rendersTerminalOutput: true
        )
    }

    public var capabilities: AgentCapabilities {
        AgentCapabilities(
            sessionID: .presetByApp,
            lifecycle: .hooks,
            acceptsPrompts: true,
            answersApprovalsInTerminal: true,
            usage: .claudeStatusLine,
            tracksSubagents: true,
            presetPlaceholder: "--model opus",
            settingsSections: [.claudeShellHooks]
        )
    }

    public func launchCommand(for context: LaunchContext) -> LaunchCommand {
        // Without a preset id Claude picks its own; the SessionStart hook reports it. The id is
        // attached to its option here and for a resume, so it can never be read as one itself.
        let idArguments = context.agentSessionID.flatMap { acceptsSessionID($0) ? ["--session-id=\($0)"] : nil } ?? []
        return LaunchCommand(
            executable: executableName,
            arguments: idArguments + ["--settings", Self.hookSettings(hook: context.hookExecutableURL)],
            environment: Self.environment(context)
        )
    }

    public func resumeCommand(for context: LaunchContext, agentSessionID: String) -> LaunchCommand? {
        guard acceptsSessionID(agentSessionID) else { return nil }
        return LaunchCommand(
            executable: executableName,
            arguments: [
                "--resume=\(agentSessionID)",
                "--settings", Self.hookSettings(hook: context.hookExecutableURL),
            ],
            environment: Self.environment(context)
        )
    }

    /// Claude's conversation ids are UUIDs, and `--session-id` takes nothing else.
    public func acceptsSessionID(_ id: String) -> Bool { AgentSessionID.isUUID(id) }

    public func attentionReason(forTerminalNotification body: String) -> AttentionReason? {
        // A launched Claude reports through hooks and never gets here. A hand-started one without
        // them prints "waiting for input" after every turn, which must not count as a question.
        ClaudeTerminalNotification.reason(forBody: body)
    }

    public func decodeHook(source: String, payload: [String: Any], receivedAt date: Date) -> DecodedHook? {
        if source == Self.statusLineSource {
            // API key accounts get no limits but still get the context.
            let usage = UsageDecoder.claudeStatusLine(payload, at: date)
            let context = UsageDecoder.claudeContext(payload)
            // Before the first reply there is neither, but the status line already says where
            // the conversation will be written and which model it runs on.
            let transcriptPath = UsageDecoder.claudeTranscriptPath(payload)
            let model = UsageDecoder.claudeModel(payload)
            guard usage != nil || context != nil || transcriptPath != nil || model != nil else { return nil }
            return DecodedHook(
                event: nil, agentSessionID: nil, usage: usage, context: context, transcriptPath: transcriptPath, model: model
            )
        }
        return DecodedHook(
            event: Self.event(payload),
            agentSessionID: sessionID(payload["session_id"]),
            lifecycle: Self.lifecycle(payload),
            // Only the main agent's word is taken for it: a subagent has a transcript of its own.
            transcriptPath: HookDecoder.nonEmptyString(payload["agent_id"]) == nil ? UsageDecoder.claudeTranscriptPath(payload) : nil
        )
    }

    /// SessionStart and SessionEnd, with what started or ended the conversation. Only a hand-started
    /// Claude needs these. For one the app launched, the terminal reports the exit.
    static func lifecycle(_ payload: [String: Any]) -> HookLifecycle? {
        guard HookDecoder.nonEmptyString(payload["agent_id"]) == nil else { return nil }
        switch payload["hook_event_name"] as? String {
        case "SessionStart": return .started(source: HookDecoder.nonEmptyString(payload["source"]))
        case "SessionEnd": return .ended(reason: HookDecoder.nonEmptyString(payload["reason"]))
        default: return nil
        }
    }

    /// Field names follow the Claude Code hooks reference; anything unrecognised maps to nil.
    static func event(_ payload: [String: Any]) -> AgentEvent? {
        // Hooks fired inside a subagent carry its id. They must not be read as the main agent's:
        // a subagent's StopFailure would otherwise end the parent's turn.
        let agentID = HookDecoder.nonEmptyString(payload["agent_id"])
        if let agentID {
            switch payload["hook_event_name"] as? String {
            case "SubagentStart": return .subagentStarted(id: agentID)
            case "SubagentStop", "StopFailure", "Stop": return .subagentFinished(id: agentID)
            case "PreToolUse", "PostToolUse": return .subagentActivity(id: agentID)
            default: break
            }
        }
        switch payload["hook_event_name"] as? String {
        case "SessionStart":
            // Compacting starts no new conversation: the turn and its subagents carry on.
            return payload["source"] as? String == "compact" ? nil : .sessionStarted
        case "UserPromptSubmit":
            return .promptSubmitted
        case "PreToolUse", "PostToolUse":
            return .activity
        case "PermissionRequest":
            let summary = ToolRequestSummary(toolName: payload["tool_name"], toolInput: payload["tool_input"])
            return .attentionRequested(
                .permission,
                message: summary?.text,
                subagent: agentID,
                isPartial: summary?.isComplete != true
            )
        case "Notification":
            let message = HookDecoder.nonEmptyString(payload["message"])
            switch payload["notification_type"] as? String {
            case "permission_prompt":
                // Comes after the PermissionRequest hook for the same prompt, and only says that
                // some permission is needed.
                return .attentionReminder(.permission, message: message)
            case "idle_prompt":
                // Claude sends this about a minute after any turn ends, when nobody has typed. It
                // carries nothing new: the turn is already finished, and real questions arrive as a
                // permission request or an elicitation. Treating it as attention turned every
                // finished turn into "waiting for you".
                return nil
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return .attentionRequested(.question, message: message, subagent: agentID)
            default:
                return nil
            }
        case "Stop", "StopFailure":
            // StopFailure and older versions of Claude send no list. Both values are nil then,
            // and what an earlier Stop reported is kept.
            let tasks = payload["background_tasks"] as? [[String: Any]]
            return .turnFinished(
                message: HookDecoder.nonEmptyString(payload["last_assistant_message"]),
                backgroundTasks: tasks?.count { !isSubagent($0) },
                subagents: tasks?.filter(isSubagent).compactMap { HookDecoder.nonEmptyString($0["id"]) }
            )
        default:
            // SessionEnd included: the terminal reports the process exit with its real code.
            return nil
        }
    }

    /// Subagents are kept apart from shells and monitors in `background_tasks`. Their `id` is the
    /// `agent_id` SubagentStart and SubagentStop report, and unlike a dev server they do end.
    private static func isSubagent(_ task: [String: Any]) -> Bool {
        task["type"] as? String == "subagent"
    }

    /// Claude hook events we subscribe to. PostToolUse and StopFailure are there so a session
    /// leaves the attention state once a permission is granted, and leaves the working state
    /// when a turn dies on an API error (Stop does not fire then).
    static let hookEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "SessionEnd", "SubagentStart", "SubagentStop",
    ]

    static func hookHandler(command: String) -> [String: Any] {
        ["type": "command", "command": command, "timeout": 5]
    }

    static func hookSettings(hook: URL) -> String {
        // Claude runs hook commands through a shell, so the path must be quoted.
        let handler = hookHandler(command: ShellQuoting.quote(hook.path))
        var hooks: [String: Any] = [:]
        for event in hookEvents {
            hooks[event] = [["hooks": [handler]]]
        }
        // Claude hands the status line its rate limits, which nothing else exposes. archipel-hook passes
        // them on and then runs the user's own status line, so the terminal looks the same as it does
        // outside Archipel.
        let statusLine: [String: Any] = [
            "type": "command",
            "command": ShellQuoting.quote(hook.path) + " statusline",
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: ["hooks": hooks, "statusLine": statusLine],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// The flag that makes Archipel's entries in the user's settings skip this Claude. A terminal
    /// Claude already reports through `--settings`, and a chat one through the protocol. A Claude it
    /// starts inherits the flag.
    static let launchedByArchipelEnvironment = [
        ClaudeUserHooks.launchedByArchipelVariable: ClaudeUserHooks.launchedByArchipelValue,
    ]

    static func environment(_ context: LaunchContext) -> [String: String] {
        hookEnvironment(context).merging(launchedByArchipelEnvironment) { $1 }
    }
}
